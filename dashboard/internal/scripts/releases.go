package scripts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var imageVersionTagPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)

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
		return versionTagsOnly(splitUnique(raw))
	}

	entries := loadReleaseMetadata()
	versions := make([]string, 0, len(entries)+1)
	versions = append(versions, strings.TrimSpace(os.Getenv("APP_IMAGE_VERSION_DEFAULT")))
	for _, entry := range entries {
		versions = append(versions, entry.Tag)
	}
	if out := versionTagsOnly(uniqueNonEmpty(versions)); len(out) > 0 {
		return out
	}

	return []string{"v0.0.1"}
}

func releaseMetadataByTag() map[string]releaseMetadata {
	out := map[string]releaseMetadata{}
	for _, entry := range loadReleaseMetadata() {
		entry.Tag = strings.TrimSpace(entry.Tag)
		if !IsImageVersionTag(entry.Tag) {
			continue
		}
		entry.Status = strings.TrimSpace(entry.Status)
		out[entry.Tag] = entry
	}
	return out
}

func IsImageVersionTag(tag string) bool {
	return imageVersionTagPattern.MatchString(strings.TrimSpace(tag))
}

func versionTagsOnly(in []string) []string {
	out := []string{}
	for _, tag := range in {
		if IsImageVersionTag(tag) {
			out = append(out, strings.TrimSpace(tag))
		}
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
