package scripts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

type releaseMetadata struct {
	Tag    string   `json:"tag"`
	Date   string   `json:"date"`
	Status string   `json:"status"`
	Broken bool     `json:"broken"`
	Title  string   `json:"title"`
	Notes  []string `json:"notes"`
}

func versionOptions() []string {
	if raw := strings.TrimSpace(os.Getenv("APP_IMAGE_VERSIONS")); raw != "" {
		return splitUnique(raw)
	}

	entries := loadReleaseMetadata()
	versions := make([]string, 0, len(entries)+1)
	versions = append(versions, strings.TrimSpace(os.Getenv("APP_IMAGE_VERSION_DEFAULT")))
	for _, entry := range entries {
		versions = append(versions, entry.Tag)
	}
	if out := uniqueNonEmpty(versions); len(out) > 0 {
		return out
	}

	return []string{"v2.4.51", "v2.4.50", "v2.4.49"}
}

func releaseMetadataByTag() map[string]releaseMetadata {
	out := map[string]releaseMetadata{}
	for _, entry := range loadReleaseMetadata() {
		entry.Tag = strings.TrimSpace(entry.Tag)
		if entry.Tag == "" {
			continue
		}
		entry.Status = strings.TrimSpace(entry.Status)
		if strings.EqualFold(entry.Status, "broken") {
			entry.Broken = true
		}
		if entry.Broken {
			entry.Status = "broken"
		}
		out[entry.Tag] = entry
	}
	for _, tag := range splitUnique(os.Getenv("APP_IMAGE_BROKEN_VERSIONS")) {
		entry := out[tag]
		entry.Tag = tag
		entry.Status = "broken"
		entry.Broken = true
		out[tag] = entry
	}
	return out
}

func loadReleaseMetadata() []releaseMetadata {
	for _, path := range releaseFileCandidates() {
		path = strings.TrimSpace(path)
		if path == "" {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var entries []releaseMetadata
		if err := json.Unmarshal(data, &entries); err == nil {
			return entries
		}
	}
	return nil
}

func releaseFileCandidates() []string {
	out := []string{}
	if v := strings.TrimSpace(os.Getenv("APP_IMAGE_RELEASES_FILE")); v != "" {
		out = append(out, v)
	}
	if deploymentDir := strings.TrimSpace(os.Getenv("DEPLOYMENT_DIR")); deploymentDir != "" {
		out = append(out,
			filepath.Join(deploymentDir, "dashboard", "releases.json"),
			filepath.Join(deploymentDir, "releases.json"),
		)
	}
	return append(out,
		"releases.json",
		filepath.Join("dashboard", "releases.json"),
		filepath.Join("..", "releases.json"),
	)
}

func splitUnique(raw string) []string {
	parts := strings.FieldsFunc(raw, func(r rune) bool { return r == ',' || r == '\n' || r == ' ' || r == '\t' })
	return uniqueNonEmpty(parts)
}

func uniqueNonEmpty(in []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, v := range in {
		v = strings.TrimSpace(v)
		if v == "" || seen[v] {
			continue
		}
		seen[v] = true
		out = append(out, v)
	}
	return out
}
