package limiter

import "testing"

func TestProbePolicyBoundaries(t *testing.T) {
	p, err := ParsePolicy("POST /api/v2/documents=1:1, ANY /api/v2/any=2:2", "/internal,/healthz,/metrics", "/internal/storage/events", "s3cr3t")
	if err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name   string
		method string
		path   string
		auth   string
		exempt bool
		routes int
	}{
		{name: "internal root", method: "GET", path: "/internal", exempt: true},
		{name: "internal child", method: "GET", path: "/internal/x", exempt: true},
		{name: "internalx not exempt", method: "GET", path: "/internalx", exempt: false},
		{name: "healthzfoo not exempt", method: "GET", path: "/healthzfoo", exempt: false},
		{name: "metricsx not exempt", method: "GET", path: "/metricsx", exempt: false},
		{name: "traversal to healthz", method: "GET", path: "/internal/../healthz", exempt: false},
		{name: "double slash internal", method: "GET", path: "//internal", exempt: false},
		{name: "traversal to internal", method: "GET", path: "/x/../internal", exempt: false},
		{name: "webhook no token", method: "POST", path: "/internal/storage/events", exempt: false},
		{name: "webhook wrong token", method: "POST", path: "/internal/storage/events", auth: "Bearer wrong", exempt: false},
		{name: "webhook non-bearer", method: "POST", path: "/internal/storage/events", auth: "s3cr3t", exempt: false},
		{name: "webhook empty bearer", method: "POST", path: "/internal/storage/events", auth: "Bearer ", exempt: false},
		{name: "webhook valid token", method: "POST", path: "/internal/storage/events", auth: "Bearer s3cr3t", exempt: true},
		{name: "webhook subpath no token not exempt", method: "POST", path: "/internal/storage/events/child", exempt: false},
		{name: "webhook traversal no exemption", method: "POST", path: "/internal/../internal/storage/events", auth: "Bearer s3cr3t", exempt: false},
		{name: "sensitive normalized", method: "post", path: "/internal/../api/v2/documents?trace=1", routes: 1},
		{name: "sensitive method mismatch", method: "GET", path: "/api/v2/documents", routes: 0},
		{name: "sensitive exact path only", method: "POST", path: "/api/v2/documents/123", routes: 0},
		{name: "ANY method route", method: "DELETE", path: "/api/v2/any", routes: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			plan := p.Decide(Request{Method: tc.method, Path: tc.path, Authorization: tc.auth})
			if plan.Exempt != tc.exempt {
				t.Fatalf("Exempt = %v, want %v", plan.Exempt, tc.exempt)
			}
			if tc.routes > 0 && len(plan.Routes) != tc.routes {
				t.Fatalf("routes = %d, want %d", len(plan.Routes), tc.routes)
			}
		})
	}
}

func TestProbeWebhookNoConfiguredToken(t *testing.T) {
	p, err := ParsePolicy("", "/internal", "/internal/storage/events", "")
	if err != nil {
		t.Fatal(err)
	}
	plan := p.Decide(Request{Method: "POST", Path: "/internal/storage/events", Authorization: "Bearer any"})
	if plan.Exempt {
		t.Fatal("webhook with no configured token must not be exempt")
	}
}

func TestProbeNonCanonicalExemptPathsLimited(t *testing.T) {
	p, _ := ParsePolicy("POST /api/v2/documents=1:1", "/internal,/healthz,/metrics", "/internal/storage/events", "s3cr3t")
	for _, uri := range []string{"//healthz", "/internal/../healthz"} {
		plan := p.Decide(Request{Method: "GET", Path: uri})
		if plan.Exempt {
			t.Fatalf("non-canonical path %q gained exemption", uri)
		}
	}
}
