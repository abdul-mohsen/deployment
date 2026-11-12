package web

import (
	"strings"
	"testing"
)

func TestIndexTemplateContainsAdminMasterMigrationControls(t *testing.T) {
	template := embeddedTemplate(t, "index.html")
	for _, want := range []string{
		`{{if .IsAdmin}}`,
		`id="zatca-master-migration-panel"`,
		`id="zatca-master-migration-badge"`,
		`id="zatca-master-migration-run"`,
		`/api/migrations/zatca-master`,
		`/api/migrations/zatca-master/run`,
		`state === 'running'`,
		`error.textContent`,
	} {
		if !strings.Contains(template, want) {
			t.Errorf("index template missing %q", want)
		}
	}
}
