package vendor

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	githubRepo    = "enigmaneering/vendor"
	defaultVersion = "v0.0.42"
)

// GetExternalDir returns the path where vendor libraries should be installed
// Defaults to ./external relative to the caller's working directory
func GetExternalDir() string {
	if dir := os.Getenv("VENDOR_EXTERNAL_DIR"); dir != "" {
		return dir
	}
	return "external"
}

// EnsureLibraries downloads and extracts all vendor libraries if not present
func EnsureLibraries() error {
	return EnsureLibrariesVersion(defaultVersion)
}

// EnsureLibrariesVersion downloads and extracts vendor libraries for a specific version
func EnsureLibrariesVersion(version string) error {
	externalDir := GetExternalDir()

	// Check if already installed
	if isInstalled(externalDir) {
		return nil
	}

	platform := detectPlatform()
	if platform == "" {
		return fmt.Errorf("unsupported platform: %s/%s", runtime.GOOS, runtime.GOARCH)
	}

	// Download each library
	libraries := []string{"glslang", "spirv-cross", "dxc"}
	for _, lib := range libraries {
		if err := downloadLibrary(lib, platform, version, externalDir); err != nil {
			return fmt.Errorf("failed to download %s: %w", lib, err)
		}
	}

	// Download LICENSE and README files
	if err := downloadLicenseFiles(version, externalDir); err != nil {
		return fmt.Errorf("failed to download license files: %w", err)
	}

	return nil
}

// isInstalled checks if vendor libraries are already present
func isInstalled(externalDir string) bool {
	// Check for key binaries/libraries
	markers := []string{
		filepath.Join(externalDir, "glslang"),
		filepath.Join(externalDir, "spirv-cross"),
		filepath.Join(externalDir, "dxc"),
	}

	for _, marker := range markers {
		if _, err := os.Stat(marker); os.IsNotExist(err) {
			return false
		}
	}

	return true
}

// detectPlatform returns the platform string for GitHub release artifacts
func detectPlatform() string {
	goos := runtime.GOOS
	goarch := runtime.GOARCH

	var os, arch string
	switch goos {
	case "darwin":
		os = "darwin"
	case "linux":
		os = "linux"
	case "windows":
		os = "windows"
	default:
		return ""
	}

	switch goarch {
	case "amd64":
		arch = "amd64"
	case "arm64":
		arch = "arm64"
	default:
		return ""
	}

	return fmt.Sprintf("%s-%s", os, arch)
}

// downloadLibrary downloads and extracts a single library
func downloadLibrary(library, platform, version, externalDir string) error {
	// Determine file extension based on platform
	ext := ".tar.gz"
	if strings.HasPrefix(platform, "windows-") {
		ext = ".zip"
	}

	filename := fmt.Sprintf("%s-%s%s", library, platform, ext)
	url := fmt.Sprintf("https://github.com/%s/releases/download/%s/%s", githubRepo, version, filename)

	fmt.Printf("Downloading %s from %s...\n", library, url)

	// Download file
	resp, err := http.Get(url)
	if err != nil {
		return fmt.Errorf("failed to download: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download failed with status: %s", resp.Status)
	}

	// Create temporary file
	tmpFile, err := os.CreateTemp("", fmt.Sprintf("%s-*.%s", library, ext))
	if err != nil {
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	// Write to temp file
	if _, err := io.Copy(tmpFile, resp.Body); err != nil {
		return fmt.Errorf("failed to write temp file: %w", err)
	}

	// Extract based on file type
	tmpFile.Close() // Close before extraction

	if ext == ".tar.gz" {
		if err := extractTarGz(tmpFile.Name(), externalDir); err != nil {
			return fmt.Errorf("failed to extract tar.gz: %w", err)
		}
	} else {
		if err := extractZip(tmpFile.Name(), externalDir); err != nil {
			return fmt.Errorf("failed to extract zip: %w", err)
		}
	}

	fmt.Printf("Successfully installed %s\n", library)
	return nil
}

// extractTarGz extracts a .tar.gz file
func extractTarGz(archivePath, destDir string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer file.Close()

	gzr, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)

	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		target := filepath.Join(destDir, header.Name)

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
				return err
			}
			outFile, err := os.OpenFile(target, os.O_CREATE|os.O_RDWR|os.O_TRUNC, os.FileMode(header.Mode))
			if err != nil {
				return err
			}
			if _, err := io.Copy(outFile, tr); err != nil {
				outFile.Close()
				return err
			}
			outFile.Close()
		}
	}

	return nil
}

// downloadLicenseFiles downloads LICENSE and README from the vendor repo
func downloadLicenseFiles(version, externalDir string) error {
	files := []string{"LICENSES.md", "README.md"}

	for _, filename := range files {
		url := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/%s", githubRepo, version, filename)
		destPath := filepath.Join(externalDir, filename)

		fmt.Printf("Downloading %s...\n", filename)

		resp, err := http.Get(url)
		if err != nil {
			return fmt.Errorf("failed to download %s: %w", filename, err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("download %s failed with status: %s", filename, resp.Status)
		}

		outFile, err := os.Create(destPath)
		if err != nil {
			return fmt.Errorf("failed to create %s: %w", filename, err)
		}
		defer outFile.Close()

		if _, err := io.Copy(outFile, resp.Body); err != nil {
			return fmt.Errorf("failed to write %s: %w", filename, err)
		}

		fmt.Printf("Successfully downloaded %s\n", filename)
	}

	return nil
}

// extractZip extracts a .zip file
func extractZip(archivePath, destDir string) error {
	r, err := zip.OpenReader(archivePath)
	if err != nil {
		return err
	}
	defer r.Close()

	for _, f := range r.File {
		target := filepath.Join(destDir, f.Name)

		if f.FileInfo().IsDir() {
			os.MkdirAll(target, 0755)
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}

		outFile, err := os.OpenFile(target, os.O_CREATE|os.O_RDWR|os.O_TRUNC, f.Mode())
		if err != nil {
			return err
		}

		rc, err := f.Open()
		if err != nil {
			outFile.Close()
			return err
		}

		_, err = io.Copy(outFile, rc)
		outFile.Close()
		rc.Close()

		if err != nil {
			return err
		}
	}

	return nil
}
