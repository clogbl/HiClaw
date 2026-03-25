package executor

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// PackageResolver handles file://, http(s)://, and nacos:// package URIs.
type PackageResolver struct {
	ImportDir string // e.g. /tmp/import
}

func NewPackageResolver(importDir string) *PackageResolver {
	return &PackageResolver{ImportDir: importDir}
}

// Resolve downloads or locates a package and returns the local path.
// Supported schemes: file://, http://, https://, nacos://
func (p *PackageResolver) Resolve(ctx context.Context, uri string) (string, error) {
	if uri == "" {
		return "", nil
	}

	parsed, err := url.Parse(uri)
	if err != nil {
		return "", fmt.Errorf("invalid package URI %q: %w", uri, err)
	}

	switch parsed.Scheme {
	case "file":
		return p.resolveFile(parsed)
	case "http", "https":
		return p.resolveHTTP(ctx, uri)
	case "nacos":
		return p.resolveNacos(ctx, parsed)
	default:
		// Treat as local path for backward compatibility
		localPath := filepath.Join(p.ImportDir, filepath.Base(uri))
		if _, err := os.Stat(localPath); err == nil {
			return localPath, nil
		}
		return "", fmt.Errorf("unsupported package scheme %q (use file://, http(s)://, or nacos://)", parsed.Scheme)
	}
}

func (p *PackageResolver) resolveFile(u *url.URL) (string, error) {
	// file://./foo.zip → look in ImportDir
	filename := filepath.Base(u.Path)
	localPath := filepath.Join(p.ImportDir, filename)

	if _, err := os.Stat(localPath); err != nil {
		// Try the raw path
		if _, err2 := os.Stat(u.Path); err2 != nil {
			return "", fmt.Errorf("file package not found at %s or %s", localPath, u.Path)
		}
		return u.Path, nil
	}
	return localPath, nil
}

func (p *PackageResolver) resolveHTTP(ctx context.Context, uri string) (string, error) {
	filename := filepath.Base(uri)
	if !strings.HasSuffix(filename, ".zip") {
		filename += ".zip"
	}
	destPath := filepath.Join(p.ImportDir, filename)

	// Skip download if already exists
	if _, err := os.Stat(destPath); err == nil {
		return destPath, nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, uri, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request for %s: %w", uri, err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to download %s: %w", uri, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download %s returned status %d", uri, resp.StatusCode)
	}

	out, err := os.Create(destPath)
	if err != nil {
		return "", fmt.Errorf("failed to create %s: %w", destPath, err)
	}
	defer out.Close()

	if _, err := io.Copy(out, resp.Body); err != nil {
		os.Remove(destPath)
		return "", fmt.Errorf("failed to write %s: %w", destPath, err)
	}

	return destPath, nil
}

// resolveNacos pulls a package from Nacos configuration center.
// URI format: nacos://{instance-id}/{namespace}/{group}/{data-id}/{version}
// Requires HICLAW_NACOS_* environment variables for connection info.
func (p *PackageResolver) resolveNacos(ctx context.Context, u *url.URL) (string, error) {
	// Parse URI path segments: /{namespace}/{group}/{data-id}/{version}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 3 {
		return "", fmt.Errorf("invalid nacos URI: expected nacos://{instance}/{namespace}/{group}/{data-id}[/{version}], got %s", u.String())
	}

	instanceID := u.Host
	namespace := parts[0]
	group := parts[1]
	dataID := parts[2]
	version := ""
	if len(parts) >= 4 {
		version = parts[3]
	}

	// Resolve Nacos server address from environment
	nacosAddr := os.Getenv("HICLAW_NACOS_ADDR")
	if nacosAddr == "" {
		return "", fmt.Errorf("HICLAW_NACOS_ADDR not set (required for nacos:// packages, instance=%s)", instanceID)
	}
	nacosToken := os.Getenv("HICLAW_NACOS_TOKEN")

	// Build Nacos Open API URL to fetch config
	// GET /nacos/v1/cs/configs?tenant={namespace}&group={group}&dataId={dataId}
	apiURL := fmt.Sprintf("%s/nacos/v1/cs/configs?tenant=%s&group=%s&dataId=%s",
		strings.TrimRight(nacosAddr, "/"),
		url.QueryEscape(namespace),
		url.QueryEscape(group),
		url.QueryEscape(dataID),
	)
	if version != "" {
		apiURL += "&tag=" + url.QueryEscape(version)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create nacos request: %w", err)
	}
	if nacosToken != "" {
		req.Header.Set("accessToken", nacosToken)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to fetch from nacos (%s): %w", apiURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("nacos returned status %d for %s/%s/%s", resp.StatusCode, namespace, group, dataID)
	}

	// Save response to import dir
	destName := fmt.Sprintf("%s-%s.zip", dataID, version)
	if version == "" {
		destName = dataID + ".zip"
	}
	destPath := filepath.Join(p.ImportDir, destName)

	out, err := os.Create(destPath)
	if err != nil {
		return "", fmt.Errorf("failed to create %s: %w", destPath, err)
	}
	defer out.Close()

	if _, err := io.Copy(out, resp.Body); err != nil {
		os.Remove(destPath)
		return "", fmt.Errorf("failed to write %s: %w", destPath, err)
	}

	return destPath, nil
}
