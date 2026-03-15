package external

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	githubRepo = "enigmaneering/external"
)

// GitHubRelease represents a GitHub release
type GitHubRelease struct {
	TagName string `json:"tag_name"`
}

// GetExternalDir returns the path where external libraries should be installed
// Defaults to ./external relative to the caller's working directory
func GetExternalDir() string {
	if dir := os.Getenv("EXTERNAL_DIR"); dir != "" {
		return dir
	}
	return "external"
}

// getLatestVersion queries GitHub for the latest release tag
func getLatestVersion() (string, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", githubRepo)

	resp, err := http.Get(url)
	if err != nil {
		return "", fmt.Errorf("failed to query GitHub API: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub API returned status: %s", resp.Status)
	}

	var release GitHubRelease
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return "", fmt.Errorf("failed to parse GitHub response: %w", err)
	}

	if release.TagName == "" {
		return "", fmt.Errorf("no tag name in GitHub response")
	}

	return release.TagName, nil
}

// EnsureLibraries downloads and extracts all external libraries if not present
// Automatically uses the latest release version and re-downloads if a newer version is available
// If a 'freeze' file exists in the external directory, automatic updates are disabled
func EnsureLibraries() error {
	externalDir := GetExternalDir()

	// Check if frozen - if so, only install if nothing is present
	if isFrozen(externalDir) {
		installedVersion, err := getInstalledVersion(externalDir)
		if err == nil && installedVersion != "" {
			fmt.Printf("External libraries frozen at version %s\n", installedVersion)
			fmt.Printf("(Remove 'freeze' file in external directory to enable automatic updates)\n")
			return nil
		}
		// Frozen but nothing installed - still need initial install
		fmt.Printf("External libraries frozen, but nothing installed yet\n")
		fmt.Printf("Please manually download a release or remove 'freeze' file\n")
		return fmt.Errorf("frozen external directory with no libraries installed")
	}

	version, err := getLatestVersion()
	if err != nil {
		return fmt.Errorf("failed to determine latest version: %w", err)
	}

	// Check if we already have this version installed
	installedVersion, err := getInstalledVersion(externalDir)
	if err == nil && installedVersion == version {
		fmt.Printf("External libraries already up-to-date (%s)\n", version)
		return nil
	}

	if installedVersion != "" {
		fmt.Printf("Upgrading external libraries: %s → %s\n", installedVersion, version)
		// Clean out old version
		if err := cleanExternalDir(externalDir); err != nil {
			return fmt.Errorf("failed to clean external directory: %w", err)
		}
	} else {
		fmt.Printf("Installing external libraries: %s\n", version)
	}

	return EnsureLibrariesVersion(version)
}

// EnsureLibrariesVersion downloads and extracts external libraries for a specific version
func EnsureLibrariesVersion(version string) error {
	externalDir := GetExternalDir()

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

	// Download LICENSE and README files (non-fatal if missing in older releases)
	if err := downloadLicenseFiles(version, externalDir); err != nil {
		fmt.Printf("Warning: Could not download license files: %v\n", err)
		fmt.Printf("This is expected for older releases. License files are available in the repository.\n")
	}

	// Write version file to track what's installed
	if err := writeVersionFile(externalDir, version); err != nil {
		fmt.Printf("Warning: Could not write version file: %v\n", err)
	}

	return nil
}

// isInstalled checks if external libraries are already present
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
	// Determine file extension based on library and platform
	ext := ".tar.gz"
	if library == "dxc" && strings.HasPrefix(platform, "windows-") {
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
		if err := extractTarGz(tmpFile.Name(), externalDir, library, platform); err != nil {
			return fmt.Errorf("failed to extract tar.gz: %w", err)
		}
	} else {
		if err := extractZip(tmpFile.Name(), externalDir, library, platform); err != nil {
			return fmt.Errorf("failed to extract zip: %w", err)
		}
	}

	fmt.Printf("Successfully installed %s\n", library)
	return nil
}

// extractTarGz extracts a .tar.gz file and renames the root directory
func extractTarGz(archivePath, destDir, library, platform string) error {
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
	platformPrefix := fmt.Sprintf("%s-%s", library, platform)

	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		// Strip platform suffix from path
		name := header.Name
		if strings.HasPrefix(name, platformPrefix+"/") {
			name = library + name[len(platformPrefix):]
		} else if name == platformPrefix {
			name = library
		}

		target := filepath.Join(destDir, name)

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

// downloadLicenseFiles downloads LICENSE files and README from the external repo
func downloadLicenseFiles(version, externalDir string) error {
	// Create LICENSES subdirectory
	licensesDir := filepath.Join(externalDir, "LICENSES")
	if err := os.MkdirAll(licensesDir, 0755); err != nil {
		return fmt.Errorf("failed to create LICENSES directory: %w", err)
	}

	// Download individual license files
	licenseFiles := []string{
		"DXC.LICENSE",
		"glslang.LICENSE",
		"SPIRV-Cross.LICENSE",
		"SPIRV-Headers.LICENSE",
		"SPIRV-Tools.LICENSE",
		"README.md",
	}

	for _, filename := range licenseFiles {
		url := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/LICENSES/%s", githubRepo, version, filename)
		destPath := filepath.Join(licensesDir, filename)

		fmt.Printf("Downloading LICENSES/%s...\n", filename)

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

		fmt.Printf("Successfully downloaded LICENSES/%s\n", filename)
	}

	// Download main README.md to external root
	url := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/README.md", githubRepo, version)
	destPath := filepath.Join(externalDir, "README.md")

	fmt.Printf("Downloading README.md...\n")

	resp, err := http.Get(url)
	if err != nil {
		return fmt.Errorf("failed to download README.md: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download README.md failed with status: %s", resp.Status)
	}

	outFile, err := os.Create(destPath)
	if err != nil {
		return fmt.Errorf("failed to create README.md: %w", err)
	}
	defer outFile.Close()

	if _, err := io.Copy(outFile, resp.Body); err != nil {
		return fmt.Errorf("failed to write README.md: %w", err)
	}

	fmt.Printf("Successfully downloaded README.md\n")

	return nil
}

// getInstalledVersion reads the version file to determine what's currently installed
func getInstalledVersion(externalDir string) (string, error) {
	versionFile := filepath.Join(externalDir, ".version")
	data, err := os.ReadFile(versionFile)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

// writeVersionFile writes the current version to a file for future checks
func writeVersionFile(externalDir, version string) error {
	versionFile := filepath.Join(externalDir, ".version")
	return os.WriteFile(versionFile, []byte(version+"\n"), 0644)
}

// cleanExternalDir removes all library directories to prepare for new installation
func cleanExternalDir(externalDir string) error {
	dirsToClean := []string{"glslang", "spirv-cross", "dxc"}
	for _, dir := range dirsToClean {
		libDir := filepath.Join(externalDir, dir)
		if err := os.RemoveAll(libDir); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("failed to remove %s: %w", libDir, err)
		}
	}
	return nil
}

// isFrozen checks if a 'freeze' file exists in the external directory
// If present, automatic updates are disabled
func isFrozen(externalDir string) bool {
	freezeFile := filepath.Join(externalDir, "freeze")
	_, err := os.Stat(freezeFile)
	return err == nil
}

// extractZip extracts a .zip file and renames the root directory
func extractZip(archivePath, destDir, library, platform string) error {
	r, err := zip.OpenReader(archivePath)
	if err != nil {
		return err
	}
	defer r.Close()

	platformPrefix := fmt.Sprintf("%s-%s", library, platform)

	// Ensure the library root directory exists first
	libRoot := filepath.Join(destDir, library)
	if err := os.MkdirAll(libRoot, 0755); err != nil {
		return fmt.Errorf("failed to create library root directory %s: %w", libRoot, err)
	}

	for _, f := range r.File {
		// Strip platform suffix from path
		// Normalize path separators (ZIP files may use either / or \)
		name := filepath.ToSlash(f.Name)
		if strings.HasPrefix(name, platformPrefix+"/") {
			name = library + name[len(platformPrefix):]
		} else if name == platformPrefix {
			name = library
		}

		target := filepath.Join(destDir, name)

		// Check if entry is a directory (either via FileInfo or trailing separator)
		isDir := f.FileInfo().IsDir() || strings.HasSuffix(name, "/")
		if isDir {
			if err := os.MkdirAll(target, 0755); err != nil {
				return fmt.Errorf("failed to create directory %s: %w", target, err)
			}
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
