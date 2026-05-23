package scripts

import (
	"os"
	"path/filepath"
	"testing"
)

func TestVersionCatalogUsesExplicitTagsAndBrokenList(t *testing.T) {
	t.Setenv("BACKEND_IMAGE", "ssdawweq/ifritah-api")
	t.Setenv("FRONTEND_IMAGE", "ssdawweq/ifritah-web")
	t.Setenv("APP_IMAGE_VERSIONS", "v2.4.51,v2.4.49")
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "v2.4.51")
	t.Setenv("APP_IMAGE_BROKEN_VERSIONS", "v2.4.49")

	releases := VersionCatalog()
	if len(releases) != 2 {
		t.Fatalf("expected 2 releases, got %d", len(releases))
	}
	if releases[0].Tag != "v2.4.51" || releases[0].BackendImage != "ssdawweq/ifritah-api:v2.4.51" {
		t.Fatalf("unexpected first release: %+v", releases[0])
	}
	if !releases[1].Broken || releases[1].Status != "broken" {
		t.Fatalf("expected v2.4.49 to be broken, got %+v", releases[1])
	}
}

func TestVersionCatalogCanLoadReleaseFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "releases.json")
	data := `[{"tag":"v2.4.52","status":"stable","title":"Next release","notes":["Release note"]}]`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("APP_IMAGE_RELEASES_FILE", path)
	t.Setenv("APP_IMAGE_VERSION_DEFAULT", "v2.4.52")

	releases := VersionCatalog()
	if len(releases) != 1 || releases[0].Tag != "v2.4.52" {
		t.Fatalf("expected file release, got %+v", releases)
	}
	if releases[0].Title != "Next release" || len(releases[0].Notes) != 1 {
		t.Fatalf("expected release metadata, got %+v", releases[0])
	}
}
