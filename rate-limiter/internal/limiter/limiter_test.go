package limiter

import "testing"

func TestBurstOneAllowsExactlyOne(t *testing.T) {
	now := int64(1_000_000)
	st := Calculate(now, 0, 10, 1)
	if !st.Allowed {
		t.Fatalf("primera petición debe permitirse")
	}
	if st.Remaining != 0 {
		t.Fatalf("remaining = %d, se esperaba 0", st.Remaining)
	}

	next := Calculate(now, st.NewTAT, 10, 1)
	if next.Allowed {
		t.Fatalf("segunda petición en el mismo instante debe rechazarse")
	}
	if next.RetryAfter < 1 {
		t.Fatalf("retry_after = %d, se esperaba >= 1", next.RetryAfter)
	}
}

func TestBurstAllowsExactlyN(t *testing.T) {
	now := int64(5_000_000)
	const burst = 5
	tat := int64(0)

	for i := 0; i < burst; i++ {
		st := Calculate(now, tat, 10, burst)
		if !st.Allowed {
			t.Fatalf("petición %d: se esperaba permitida", i+1)
		}
		if want := int64(burst - i - 1); st.Remaining != want {
			t.Fatalf("petición %d: remaining = %d, se esperaba %d", i+1, st.Remaining, want)
		}
		tat = st.NewTAT
	}

	st := Calculate(now, tat, 10, burst)
	if st.Allowed {
		t.Fatalf("la petición %d debe rechazarse", burst+1)
	}
}

func TestAllowsAgainAfterInterval(t *testing.T) {
	now := int64(10_000_000)
	first := Calculate(now, 0, 10, 1)
	if !first.Allowed {
		t.Fatalf("primera petición debe permitirse")
	}

	// Rate 10/s => intervalo de 100 ms.
	later := now + 100_000
	second := Calculate(later, first.NewTAT, 10, 1)
	if !second.Allowed {
		t.Fatalf("tras el intervalo la petición debe permitirse")
	}
}

func TestTTLCoversState(t *testing.T) {
	now := int64(42_000_000)
	st := Calculate(now, 0, 0.1, 1) // intervalo de 10 s
	if !st.Allowed {
		t.Fatalf("primera petición debe permitirse")
	}
	if st.TTLSeconds < 10 {
		t.Fatalf("ttl = %d, se esperaba al menos 10", st.TTLSeconds)
	}
}

func TestDeniedKeepsTAT(t *testing.T) {
	now := int64(7_000_000)
	first := Calculate(now, 0, 1, 1)
	if !first.Allowed {
		t.Fatalf("primera petición debe permitirse")
	}
	second := Calculate(now, first.NewTAT, 1, 1)
	if second.Allowed {
		t.Fatalf("segunda petición debe rechazarse")
	}
	if second.NewTAT != first.NewTAT {
		t.Fatalf("un rechazo no debe modificar el TAT")
	}
}
