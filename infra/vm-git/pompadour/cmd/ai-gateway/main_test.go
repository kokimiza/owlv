package main

import (
	"reflect"
	"testing"
)

func TestExtractLabelsFiltersToAllowedSet(t *testing.T) {
	respBody := []byte(`{"content":[{"text":"[\"bug\", \"made-up-label\", \"security\"]"}]}`)
	got, err := extractLabels(respBody, []string{"bug", "security", "enhancement"})
	if err != nil {
		t.Fatalf("extractLabels: %v", err)
	}
	want := []string{"bug", "security"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("extractLabels = %v, want %v", got, want)
	}
}

func TestExtractLabelsRejectsNonJSONText(t *testing.T) {
	respBody := []byte(`{"content":[{"text":"sure, I think this is a bug"}]}`)
	if _, err := extractLabels(respBody, []string{"bug"}); err == nil {
		t.Fatal("extractLabels: expected an error for non-JSON model output")
	}
}

func TestExtractLabelsEmptyContent(t *testing.T) {
	respBody := []byte(`{"content":[]}`)
	if _, err := extractLabels(respBody, []string{"bug"}); err == nil {
		t.Fatal("extractLabels: expected an error for empty content")
	}
}
