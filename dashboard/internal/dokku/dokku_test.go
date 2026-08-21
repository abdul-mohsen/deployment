package dokku

import "testing"

func TestParseContainerSummaryHandlesShortInspectOutput(t *testing.T) {
	got := parseContainerSummary("running\nssdawweq/ifritah-api:dev\n")
	if got.State != "running" {
		t.Fatalf("state = %q, want running", got.State)
	}
	if got.Image != "ssdawweq/ifritah-api:dev" {
		t.Fatalf("image = %q, want dev image", got.Image)
	}
}

func TestParseContainerSummaryReadsVersionFromInspectOutput(t *testing.T) {
	got := parseContainerSummary("running\nimage\n0\nAPP_IMAGE_VERSION=feature-test\n")
	if got.Version != "feature-test" {
		t.Fatalf("version = %q, want feature-test", got.Version)
	}
}
