package chatops

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"pompadour/internal/forgejo"
)

func TestParse(t *testing.T) {
	cases := []struct {
		body     string
		wantOK   bool
		wantName string
		wantArgs string
	}{
		{"/retest", true, "retest", ""},
		{"/help wanted", true, "help", "wanted"},
		{"/assign @bob", true, "assign", "@bob"},
		{"not a command", false, "", ""},
		{"/hold\nfurther prose ignored", true, "hold", ""},
		{"", false, "", ""},
	}
	for _, c := range cases {
		got, ok := Parse(c.body)
		if ok != c.wantOK {
			t.Errorf("Parse(%q) ok = %v, want %v", c.body, ok, c.wantOK)
			continue
		}
		if !ok {
			continue
		}
		if got.Name != c.wantName || got.Args != c.wantArgs {
			t.Errorf("Parse(%q) = %+v, want {%s %s}", c.body, got, c.wantName, c.wantArgs)
		}
	}
}

func TestAuthorizeNonPrivilegedAlwaysAllowed(t *testing.T) {
	ok, err := Authorize(context.Background(), nil, Command{Name: "release-note"}, "anyone")
	if err != nil {
		t.Fatalf("Authorize: %v", err)
	}
	if !ok {
		t.Fatal("release-note must not require a Forgejo lookup")
	}
}

func TestAuthorizePrivilegedChecksLivePermission(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		permission := "read"
		if r.URL.Path == "/api/v1/repos/owlv-admin/owlv/collaborators/trusted-bot/permission" {
			permission = "write"
		}
		json.NewEncoder(w).Encode(map[string]string{"permission": permission})
	}))
	defer srv.Close()

	fc := forgejo.New(srv.URL, "owlv-admin", "owlv", "test-token")

	ok, err := Authorize(context.Background(), fc, Command{Name: "hold"}, "trusted-bot")
	if err != nil {
		t.Fatalf("Authorize: %v", err)
	}
	if !ok {
		t.Fatal("expected collaborator (write permission) to be authorized for /hold")
	}

	ok, err = Authorize(context.Background(), fc, Command{Name: "hold"}, "random-commenter")
	if err != nil {
		t.Fatalf("Authorize: %v", err)
	}
	if ok {
		t.Fatal("expected read-only commenter to be denied /hold")
	}
}
