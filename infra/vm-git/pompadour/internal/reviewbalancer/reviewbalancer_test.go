package reviewbalancer

import "testing"

func TestPickPrefersLowestLoad(t *testing.T) {
	pool := []string{"alice", "bob", "carol"}
	loads := map[string]int{"alice": 5, "bob": 1, "carol": 3}

	got, ok := Pick(pool, loads, 10, nil)
	if !ok {
		t.Fatal("Pick: expected a candidate")
	}
	if got != "bob" {
		t.Fatalf("Pick = %q, want bob", got)
	}
}

func TestPickExcludesAuthor(t *testing.T) {
	pool := []string{"alice", "bob"}
	loads := map[string]int{"alice": 0, "bob": 5}

	got, ok := Pick(pool, loads, 10, map[string]bool{"alice": true})
	if !ok {
		t.Fatal("Pick: expected a candidate")
	}
	if got != "bob" {
		t.Fatalf("Pick = %q, want bob (alice excluded)", got)
	}
}

func TestPickSkipsOverCapacity(t *testing.T) {
	pool := []string{"alice", "bob"}
	loads := map[string]int{"alice": 5, "bob": 5}

	_, ok := Pick(pool, loads, 5, nil)
	if ok {
		t.Fatal("Pick: expected no candidate when everyone is at capacity")
	}
}

func TestPickTreatsMissingLoadAsZero(t *testing.T) {
	pool := []string{"alice", "newbie"}
	loads := map[string]int{"alice": 1} // "newbie" has never been assigned

	got, ok := Pick(pool, loads, 10, nil)
	if !ok {
		t.Fatal("Pick: expected a candidate")
	}
	if got != "newbie" {
		t.Fatalf("Pick = %q, want newbie (untracked == load 0)", got)
	}
}

func TestOverloaded(t *testing.T) {
	pool := []string{"alice", "bob", "carol"}
	loads := map[string]int{"alice": 15, "bob": 2, "carol": 3}

	got := Overloaded(pool, loads, 5)
	if len(got) != 1 || got[0] != "alice" {
		t.Fatalf("Overloaded = %v, want [alice]", got)
	}
}
