package web

import (
	"testing"

	"github.com/abdul-mohsen/deployment/dashboard/internal/dokku"
	"github.com/abdul-mohsen/deployment/dashboard/internal/scripts"
)

func TestBuildReleaseViewsMarksFailedDeploymentBroken(t *testing.T) {
	catalog := []scripts.ImageVersion{{Tag: "v0.0.1", Status: "ready", BackendImage: "repo/api:v0.0.1", FrontendImage: "repo/web:v0.0.1"}}
	apps := []dokku.App{
		{Name: "acme-backend", Role: "backend", Version: "v0.0.1", Image: "repo/api:v0.0.1", State: "running"},
		{Name: "acme-frontend", Role: "frontend", Version: "v0.0.1", Image: "repo/web:v0.0.1", State: "restarting"},
	}

	views := buildReleaseViews(catalog, apps)
	if len(views) != 1 {
		t.Fatalf("expected 1 release view, got %d", len(views))
	}
	if !views[0].Broken || views[0].Status != "broken" {
		t.Fatalf("expected failed deployed app to mark release broken, got %+v", views[0])
	}
	if views[0].Deployed != 2 || views[0].Failed != 1 {
		t.Fatalf("unexpected deployment counts: %+v", views[0])
	}
}

func TestBuildReleaseViewsIgnoresChannelTags(t *testing.T) {
	apps := []dokku.App{{Name: "dev-backend", Role: "backend", Version: "dev", State: "stopped"}}
	if views := buildReleaseViews(nil, apps); len(views) != 0 {
		t.Fatalf("expected channel tags to be ignored, got %+v", views)
	}
}
