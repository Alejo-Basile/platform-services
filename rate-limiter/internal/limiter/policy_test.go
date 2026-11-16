package limiter

import (
	"testing"
)

func testPolicy(t *testing.T) Policy {
	t.Helper()
	policy, err := ParsePolicy(
		"POST /api/v2/documents=5:10, /api/v2/exports=2:4, ANY /api/v2/any=3:6",
		"/internal,/healthz,/metrics",
		"/internal/storage/events",
		"s3cr3t",
	)
	if err != nil {
		t.Fatalf("ParsePolicy: %v", err)
	}
	return policy
}

func TestDecideWebhookTokenPrecedence(t *testing.T) {
	policy := testPolicy(t)
	cases := []struct {
		name          string
		path          string
		authorization string
		wantExempt    bool
	}{
		{name: "valid bearer token", path: "/internal/storage/events", authorization: "Bearer s3cr3t", wantExempt: true},
		{name: "valid token covers webhook subpath", path: "/internal/storage/events/child", authorization: "Bearer s3cr3t", wantExempt: true},
		{name: "missing token", path: "/internal/storage/events", wantExempt: false},
		{name: "wrong token", path: "/internal/storage/events", authorization: "Bearer wrong", wantExempt: false},
		{name: "non bearer token", path: "/internal/storage/events", authorization: "s3cr3t", wantExempt: false},
		{name: "empty bearer token", path: "/internal/storage/events", authorization: "Bearer ", wantExempt: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			plan := policy.Decide(Request{
				Method:        "POST",
				Path:          tc.path,
				Authorization: tc.authorization,
			})
			if plan.Exempt != tc.wantExempt {
				t.Fatalf("Exempt = %v, want %v", plan.Exempt, tc.wantExempt)
			}
			if len(plan.Routes) != 0 {
				t.Fatalf("routes = %d, want 0 for webhook", len(plan.Routes))
			}
		})
	}
}

func TestWebhookWithNoConfiguredTokenCannotBeExempt(t *testing.T) {
	policy, err := ParsePolicy("", "/internal", "/internal/storage/events", "")
	if err != nil {
		t.Fatal(err)
	}
	plan := policy.Decide(Request{
		Method:        "POST",
		Path:          "/internal/storage/events",
		Authorization: "Bearer any-token",
	})
	if plan.Exempt {
		t.Fatal("webhook without a configured token must not be exempt")
	}
}

func TestDecideExplicitExemptPathsAreSegmentAware(t *testing.T) {
	policy := testPolicy(t)
	cases := []struct {
		path       string
		wantExempt bool
	}{
		{path: "/internal", wantExempt: true},
		{path: "/internal/reconcile", wantExempt: true},
		{path: "/healthz?probe=1", wantExempt: true},
		{path: "/metrics/custom", wantExempt: true},
		{path: "/internalx", wantExempt: false},
		{path: "/healthzfoo", wantExempt: false},
		{path: "/metricsx", wantExempt: false},
		{path: "/api/v2/documents", wantExempt: false},
	}
	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			plan := policy.Decide(Request{Method: "GET", Path: tc.path})
			if plan.Exempt != tc.wantExempt {
				t.Fatalf("Exempt = %v, want %v", plan.Exempt, tc.wantExempt)
			}
		})
	}
}

func TestDecideNonCanonicalPathCannotGainExemption(t *testing.T) {
	policy := testPolicy(t)
	for _, requestPath := range []string{"/internal/../healthz", "//healthz", "/x/../internal"} {
		t.Run(requestPath, func(t *testing.T) {
			plan := policy.Decide(Request{Method: "GET", Path: requestPath})
			if plan.Exempt {
				t.Fatalf("non-canonical path %q gained an exemption", requestPath)
			}
		})
	}
}

func TestDecideSensitiveRouteUsesNormalizedExactPathAndMethod(t *testing.T) {
	policy := testPolicy(t)
	cases := []struct {
		name      string
		method    string
		path      string
		wantRoute bool
	}{
		{name: "normalized path and case-insensitive method", method: "post", path: "/internal/../api/v2/documents?trace=1", wantRoute: true},
		{name: "method mismatch", method: "GET", path: "/api/v2/documents", wantRoute: false},
		{name: "path is exact", method: "POST", path: "/api/v2/documents/123", wantRoute: false},
		{name: "methodless route applies to any method", method: "PATCH", path: "/api/v2/exports", wantRoute: true},
		{name: "ANY method applies to all methods", method: "DELETE", path: "/api/v2/any", wantRoute: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			plan := policy.Decide(Request{Method: tc.method, Path: tc.path})
			if got := len(plan.Routes) == 1; got != tc.wantRoute {
				t.Fatalf("sensitive route matched = %v, want %v (routes=%+v)", got, tc.wantRoute, plan.Routes)
			}
		})
	}
}

func TestParseLimitSpec(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		want    LimitSpec
		wantErr bool
	}{
		{name: "valid", raw: "10:20", want: LimitSpec{Rate: 10, Burst: 20}},
		{name: "decimal rate", raw: "0.5:2", want: LimitSpec{Rate: 0.5, Burst: 2}},
		{name: "zero rate", raw: "0:5", wantErr: true},
		{name: "burst below one", raw: "10:0", wantErr: true},
		{name: "missing burst", raw: "10", wantErr: true},
		{name: "nonnumeric", raw: "abc:20", wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseLimitSpec(tc.raw)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("ParseLimitSpec(%q) returned no error", tc.raw)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseLimitSpec(%q): %v", tc.raw, err)
			}
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestParseSensitiveRoutes(t *testing.T) {
	routes, err := ParseSensitiveRoutes(" POST /api/v2/documents=5:10 , /api/v2/exports=2:4 ")
	if err != nil {
		t.Fatalf("ParseSensitiveRoutes: %v", err)
	}
	if len(routes) != 2 {
		t.Fatalf("routes = %d, want 2", len(routes))
	}
	if routes[0].Method != "POST" || routes[0].Path != "/api/v2/documents" || routes[0].Limit != (LimitSpec{Rate: 5, Burst: 10}) {
		t.Fatalf("route[0] = %+v", routes[0])
	}
	if routes[1].Method != "" || routes[1].Path != "/api/v2/exports" || routes[1].Limit != (LimitSpec{Rate: 2, Burst: 4}) {
		t.Fatalf("route[1] = %+v", routes[1])
	}
}

func TestPolicyParsersRejectInvalidConfiguration(t *testing.T) {
	cases := []struct {
		name    string
		routes  string
		exempt  string
		webhook string
	}{
		{name: "missing route limit", routes: "POST /documents"},
		{name: "invalid route limit", routes: "POST /documents=0:1"},
		{name: "relative exempt path", exempt: "internal"},
		{name: "relative webhook path", webhook: "internal/events"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParsePolicy(tc.routes, tc.exempt, tc.webhook, "token")
			if err == nil {
				t.Fatal("ParsePolicy returned no error")
			}
		})
	}
}
