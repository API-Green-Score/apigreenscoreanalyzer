#!/usr/bin/env python3
"""
🌱 Creedengo Stack Detector
==============================
Auto-detects project languages, frameworks, build tools, and source directories.
Outputs a JSON manifest used by creedengo-analyzer.sh to pick the right plugins
and configure the SonarQube scanner.

Supported stacks:
  - Java   (Maven / Gradle)  → creedengo-java
  - Python (pip / poetry)     → creedengo-python
  - JavaScript / TypeScript   → creedengo-javascript (covers JS + TS)
  - C# / .NET                 → creedengo-csharp

Usage:
    python3 creedengo-detect-stack.py /path/to/project
    python3 creedengo-detect-stack.py /path/to/project --json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import Optional


# ── Creedengo plugin catalog ──
# Maps language key → { repo, artifact pattern, sonar repo id, sonar language key }
CREEDENGO_PLUGINS = {
    "java": {
        "repo": "creedengo-java",
        "legacy_repo": "ecoCode-java",
        "artifact": "creedengo-java-plugin-{version}.jar",
        "legacy_artifact": "ecocode-java-plugin-{version}.jar",
        "sonar_repo": "creedengo-java",
        "sonar_lang": "java",
    },
    "python": {
        "repo": "creedengo-python",
        "legacy_repo": "ecoCode-python",
        "artifact": "creedengo-python-plugin-{version}.jar",
        "legacy_artifact": "ecocode-python-plugin-{version}.jar",
        "sonar_repo": "creedengo-python",
        "sonar_lang": "py",
    },
    "javascript": {
        "repo": "creedengo-javascript",
        "legacy_repo": "ecoCode-javascript",
        "artifact": "creedengo-javascript-plugin-{version}.jar",
        "legacy_artifact": "ecocode-javascript-plugin-{version}.jar",
        "sonar_repo": "creedengo-javascript",
        "sonar_lang": "js",
    },
    "csharp": {
        "repo": "creedengo-csharp",
        "legacy_repo": "ecoCode-csharp",
        "artifact": "creedengo-csharp-plugin-{version}.jar",
        "legacy_artifact": "ecocode-csharp-plugin-{version}.jar",
        "sonar_repo": "creedengo-csharp",
        "sonar_lang": "cs",
    },
}


@dataclass
class ModuleInfo:
    """Detected module / sub-project."""
    name: str
    path: str                     # relative to project root
    language: str                 # java | python | javascript | typescript | csharp
    build_tool: str               # maven | gradle | pip | poetry | npm | yarn | pnpm | dotnet
    framework: str = ""           # spring-boot | django | flask | react | angular | vue | express | aspnet
    framework_version: str = ""
    language_version: str = ""    # e.g. "21", "3.12", "20"
    sources_dir: str = ""         # src/main/java, src, .
    binaries_dir: str = ""        # target/classes, dist, bin
    config_file: str = ""         # pom.xml, build.gradle, package.json, ...
    is_reactor: bool = False      # True if this is a Maven reactor/parent pom
    sub_modules: list[str] = field(default_factory=list)  # declared sub-module paths (reactor pom)
    entry_point: str = ""         # main project file (.csproj/.sln/jar) for build/run
    default_url: str = ""         # default app URL (e.g. ASP.NET launchSettings.json applicationUrl)
    notes: str = ""               # free-form notes (e.g. "F# detected — Creedengo unsupported")


@dataclass
class StackDetection:
    """Full project stack detection result."""
    project_root: str
    modules: list[ModuleInfo] = field(default_factory=list)
    languages: list[str] = field(default_factory=list)        # unique sorted
    creedengo_plugins: list[str] = field(default_factory=list) # plugin keys to download
    primary_language: str = ""
    primary_framework: str = ""
    sonar_scanner: str = "sonar-scanner"  # maven | gradle | sonar-scanner
    project_key: str = ""


def _read_text(path: Path, max_bytes: int = 200_000) -> str:
    """Safely read a text file."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")[:max_bytes]
    except Exception:
        return ""


def _extract_xml_value(content: str, tag: str) -> str:
    """Extract simple XML tag value."""
    m = re.search(rf"<{tag}>\s*(.+?)\s*</{tag}>", content, re.DOTALL)
    return m.group(1).strip() if m else ""


def _extract_xml_modules(content: str) -> list[str]:
    """Extract <modules><module>...</module></modules> from a Maven pom.xml.

    Returns a list of relative sub-module directory names (e.g. ['api', 'core', 'web']).
    Handles reactor/parent poms that declare sub-modules.
    """
    modules_block = re.search(r"<modules>(.*?)</modules>", content, re.DOTALL)
    if not modules_block:
        return []
    return re.findall(r"<module>\s*(.+?)\s*</module>", modules_block.group(1))


def _extract_json_field(content: str, key: str) -> str:
    """Extract a top-level JSON field value."""
    try:
        data = json.loads(content)
        val = data.get(key, "")
        return str(val) if val else ""
    except Exception:
        return ""


# ═══════════════════════════════════════════════════════════════════
# Language / build-tool detectors
# ═══════════════════════════════════════════════════════════════════

def detect_java_maven(root: Path) -> Optional[ModuleInfo]:
    """Detect Java project with Maven (pom.xml).

    Also detects reactor/parent poms that declare <modules>.
    Sub-module paths are stored in sub_modules for later recursive scanning.
    """
    pom = root / "pom.xml"
    if not pom.is_file():
        return None
    content = _read_text(pom)

    java_version = _extract_xml_value(content, "java.version")
    if not java_version:
        java_version = _extract_xml_value(content, "maven.compiler.source")

    # Detect reactor/parent pom with <modules>
    declared_modules = _extract_xml_modules(content)
    is_reactor = len(declared_modules) > 0

    # Framework detection
    framework, fw_version = "", ""
    if "spring-boot-starter" in content:
        framework = "spring-boot"
        fw_version = _extract_xml_value(content, "version")  # parent version
        # Try parent version more precisely
        parent_block = re.search(r"<parent>.*?</parent>", content, re.DOTALL)
        if parent_block and "spring-boot" in parent_block.group():
            fw_version = _extract_xml_value(parent_block.group(), "version")
    elif "jakarta.jakartaee-api" in content or "javax.javaee-api" in content:
        framework = "jakarta-ee"
    elif "quarkus" in content.lower():
        framework = "quarkus"
    elif "micronaut" in content.lower():
        framework = "micronaut"

    # Extract own artifactId (not parent's) — remove <parent> block first
    content_no_parent = re.sub(r"<parent>.*?</parent>", "", content, flags=re.DOTALL)
    artifact = _extract_xml_value(content_no_parent, "artifactId")

    # Reactor poms typically have <packaging>pom</packaging> and no Java sources
    packaging = _extract_xml_value(content, "packaging")
    if is_reactor or packaging == "pom":
        sources = ""
        binaries = ""
    else:
        sources = "src/main/java"
        binaries = "target/classes"

    return ModuleInfo(
        name=artifact or root.name,
        path=str(root),
        language="java",
        build_tool="maven",
        framework=framework,
        framework_version=fw_version,
        language_version=java_version or "",
        sources_dir=sources,
        binaries_dir=binaries,
        config_file="pom.xml",
        is_reactor=is_reactor,
        sub_modules=declared_modules,
    )


def detect_java_gradle(root: Path) -> Optional[ModuleInfo]:
    """Detect Java project with Gradle (build.gradle / build.gradle.kts)."""
    for name in ("build.gradle.kts", "build.gradle"):
        gf = root / name
        if gf.is_file():
            break
    else:
        return None

    content = _read_text(gf)
    java_version = ""
    m = re.search(r"sourceCompatibility\s*=\s*['\"]?(\d+)", content)
    if m:
        java_version = m.group(1)
    m2 = re.search(r"jvmToolchain\s*\(\s*(\d+)\s*\)", content)
    if m2:
        java_version = m2.group(1)

    framework, fw_version = "", ""
    if "spring-boot" in content.lower() or "org.springframework.boot" in content:
        framework = "spring-boot"
        vm = re.search(r"id\s+['\"]org\.springframework\.boot['\"]\s+version\s+['\"]([^'\"]+)", content)
        if vm:
            fw_version = vm.group(1)
    elif "quarkus" in content.lower():
        framework = "quarkus"
    elif "micronaut" in content.lower():
        framework = "micronaut"

    return ModuleInfo(
        name=root.name,
        path=str(root),
        language="java",
        build_tool="gradle",
        framework=framework,
        framework_version=fw_version,
        language_version=java_version,
        sources_dir="src/main/java",
        binaries_dir="build/classes/java/main",
        config_file=name,
    )


def detect_python(root: Path) -> Optional[ModuleInfo]:
    """Detect Python project."""
    # Check for Python markers
    markers = {
        "pyproject.toml": "poetry",
        "setup.py": "pip",
        "setup.cfg": "pip",
        "requirements.txt": "pip",
        "Pipfile": "pipenv",
    }
    config_file = ""
    build_tool = ""
    for fname, tool in markers.items():
        if (root / fname).is_file():
            config_file = fname
            build_tool = tool
            break

    if not config_file:
        # Fallback: check if there are .py files at root
        py_files = list(root.glob("*.py"))
        if not py_files:
            return None
        config_file = ""
        build_tool = "pip"

    # Detect framework
    content = ""
    framework, fw_version = "", ""
    if (root / "requirements.txt").is_file():
        content = _read_text(root / "requirements.txt")
    elif (root / "pyproject.toml").is_file():
        content = _read_text(root / "pyproject.toml")
    elif (root / "setup.py").is_file():
        content = _read_text(root / "setup.py")

    cl = content.lower()
    if "django" in cl:
        framework = "django"
    elif "flask" in cl:
        framework = "flask"
    elif "fastapi" in cl:
        framework = "fastapi"

    # Python version
    py_version = ""
    if (root / "pyproject.toml").is_file():
        pyp = _read_text(root / "pyproject.toml")
        m = re.search(r'python_requires\s*=\s*["\']>=?(\d+\.\d+)', pyp)
        if m:
            py_version = m.group(1)
        m2 = re.search(r'requires-python\s*=\s*["\']>=?(\d+\.\d+)', pyp)
        if m2:
            py_version = m2.group(1)
    if (root / ".python-version").is_file():
        py_version = _read_text(root / ".python-version").strip().split("\n")[0]

    return ModuleInfo(
        name=root.name,
        path=str(root),
        language="python",
        build_tool=build_tool,
        framework=framework,
        framework_version=fw_version,
        language_version=py_version,
        sources_dir=".",
        config_file=config_file,
    )


def detect_javascript_typescript(root: Path) -> Optional[ModuleInfo]:
    """Detect JavaScript / TypeScript project (package.json)."""
    pkg = root / "package.json"
    if not pkg.is_file():
        return None
    content = _read_text(pkg)
    try:
        data = json.loads(content)
    except Exception:
        return None

    deps = {**data.get("dependencies", {}), **data.get("devDependencies", {})}

    # Language: TS if typescript dep exists or tsconfig exists
    is_ts = "typescript" in deps or (root / "tsconfig.json").is_file()
    language = "typescript" if is_ts else "javascript"

    # Build tool
    build_tool = "npm"
    if (root / "yarn.lock").is_file():
        build_tool = "yarn"
    elif (root / "pnpm-lock.yaml").is_file():
        build_tool = "pnpm"

    # Framework
    framework, fw_version = "", ""
    if "react" in deps:
        framework = "react"
        fw_version = deps.get("react", "")
    elif "next" in deps:
        framework = "nextjs"
        fw_version = deps.get("next", "")
    elif "@angular/core" in deps:
        framework = "angular"
        fw_version = deps.get("@angular/core", "")
    elif "vue" in deps:
        framework = "vue"
        fw_version = deps.get("vue", "")
    elif "express" in deps:
        framework = "express"
        fw_version = deps.get("express", "")
    elif "nestjs" in deps or "@nestjs/core" in deps:
        framework = "nestjs"
        fw_version = deps.get("@nestjs/core", "")

    # Clean version strings (remove ^, ~, etc.)
    fw_version = re.sub(r'^[\^~>=<]+', '', fw_version)

    node_version = ""
    engines = data.get("engines", {})
    if "node" in engines:
        node_version = re.sub(r'^[\^~>=<]+', '', engines["node"])

    return ModuleInfo(
        name=data.get("name", root.name),
        path=str(root),
        language=language,
        build_tool=build_tool,
        framework=framework,
        framework_version=fw_version,
        language_version=node_version,
        sources_dir="src" if (root / "src").is_dir() else ".",
        config_file="package.json",
    )


def detect_csharp(root: Path) -> Optional[ModuleInfo]:
    """Detect C# / .NET project (.csproj / .sln / global.json).

    Also detects F# (*.fsproj) and VB.NET (*.vbproj) — emits a `notes` field
    stating Creedengo only supports C#. Reads Properties/launchSettings.json
    when present to pre-fill `default_url` for ASP.NET Core projects.
    """
    csproj_files = sorted(root.glob("*.csproj"))
    fsproj_files = sorted(root.glob("*.fsproj"))
    vbproj_files = sorted(root.glob("*.vbproj"))
    sln_files    = sorted(root.glob("*.sln"))
    global_json  = root / "global.json"

    if not (csproj_files or fsproj_files or vbproj_files or sln_files or global_json.is_file()):
        # Check one level deep (common for src/MyApi/MyApi.csproj layouts)
        csproj_files = sorted(root.glob("*/*.csproj"))
        fsproj_files = sorted(root.glob("*/*.fsproj"))
        vbproj_files = sorted(root.glob("*/*.vbproj"))
        if not (csproj_files or fsproj_files or vbproj_files):
            return None

    config_file = ""
    framework, fw_version = "", ""
    lang_version = ""
    entry_point = ""
    default_url = ""
    notes = ""

    # Prefer .sln as the entry point (multi-project solutions)
    if sln_files:
        config_file = sln_files[0].name
        entry_point = str(sln_files[0])

    primary_proj = None
    if csproj_files:
        primary_proj = csproj_files[0]
    elif fsproj_files:
        primary_proj = fsproj_files[0]
        notes = "F# project detected — Creedengo plugin only covers C#; analysis will be skipped."
    elif vbproj_files:
        primary_proj = vbproj_files[0]
        notes = "VB.NET project detected — Creedengo plugin only covers C#; analysis will be skipped."

    if primary_proj is not None:
        if not config_file:
            try:
                config_file = str(primary_proj.relative_to(root))
            except ValueError:
                config_file = primary_proj.name
        if not entry_point:
            entry_point = str(primary_proj)
        content = _read_text(primary_proj)

        # Target framework — handle both <TargetFramework> and <TargetFrameworks>
        tf = _extract_xml_value(content, "TargetFramework") \
             or _extract_xml_value(content, "TargetFrameworks")
        if tf:
            # Pick the first target if multiple are listed (e.g. "net8.0;net6.0")
            first_tf = tf.split(";")[0].strip()
            m = re.search(r"net(\d+\.?\d*)", first_tf)
            if m:
                lang_version = m.group(1)

        # ASP.NET / Worker detection
        if "Microsoft.AspNetCore" in content or 'Sdk="Microsoft.NET.Sdk.Web"' in content \
                or "Microsoft.NET.Sdk.Web" in content:
            framework = "aspnet"
        elif "Microsoft.NET.Sdk.Worker" in content:
            framework = "worker"

        # Try to read launchSettings.json (Properties/launchSettings.json next to csproj)
        ls_candidates = [
            primary_proj.parent / "Properties" / "launchSettings.json",
            root / "Properties" / "launchSettings.json",
        ]
        for ls in ls_candidates:
            if ls.is_file():
                try:
                    ls_data = json.loads(_read_text(ls))
                    profiles = ls_data.get("profiles", {}) or {}
                    # Pick the first profile that defines applicationUrl
                    for _name, prof in profiles.items():
                        url = (prof or {}).get("applicationUrl", "")
                        if url:
                            # applicationUrl can be "http://localhost:5000;https://localhost:5001"
                            # → keep the first http:// entry to avoid HTTPS dev-cert prompts
                            for u in str(url).split(";"):
                                u = u.strip()
                                if u.startswith("http://"):
                                    default_url = u
                                    break
                            if not default_url and url:
                                default_url = str(url).split(";")[0].strip()
                        if default_url:
                            break
                except Exception:
                    pass
                if default_url:
                    break

    # global.json may pin the SDK version
    if not lang_version and global_json.is_file():
        try:
            gj = json.loads(_read_text(global_json))
            sdk_ver = (gj.get("sdk", {}) or {}).get("version", "")
            if sdk_ver:
                m = re.match(r"(\d+\.?\d*)", sdk_ver)
                if m:
                    lang_version = m.group(1)
        except Exception:
            pass

    # Determine binaries dir from the lang_version if known (Debug/net8.0)
    binaries_dir = "bin"
    if lang_version:
        binaries_dir = f"bin/Debug/net{lang_version}"

    name = primary_proj.stem if primary_proj else (sln_files[0].stem if sln_files else root.name)

    return ModuleInfo(
        name=name,
        path=str(root),
        language="csharp",
        build_tool="dotnet",
        framework=framework,
        framework_version=fw_version,
        language_version=lang_version,
        sources_dir=".",
        binaries_dir=binaries_dir,
        config_file=config_file,
        entry_point=entry_point,
        default_url=default_url,
        notes=notes,
    )


# ═══════════════════════════════════════════════════════════════════
# Main detection orchestrator
# ═══════════════════════════════════════════════════════════════════

DETECTORS = [
    detect_java_maven,
    detect_java_gradle,
    detect_python,
    detect_javascript_typescript,
    detect_csharp,
]


def _lang_to_creedengo_key(lang: str) -> str:
    """Map language name to Creedengo plugin key."""
    mapping = {
        "java": "java",
        "python": "python",
        "javascript": "javascript",
        "typescript": "javascript",  # JS plugin covers TypeScript
        "csharp": "csharp",
    }
    return mapping.get(lang, "")


def detect_stack(project_root: str, scan_depth: int = 2) -> StackDetection:
    """Detect all modules/languages in a project tree.

    Scans the root directory, its immediate subdirectories (up to scan_depth),
    AND any sub-modules declared in Maven reactor pom.xml files (<modules>).
    This ensures multi-module Maven projects are fully discovered even when
    sub-modules are nested deeper than scan_depth.
    """
    root = Path(project_root).resolve()
    result = StackDetection(project_root=str(root))

    # Directories to skip
    skip_dirs = {
        "node_modules", ".git", ".idea", ".vscode", "__pycache__",
        "target", "build", "dist", "bin", "obj", ".gradle",
        ".creedengo", "reports", "dashboard", "badges", "uploads",
        "scripts", "greenanalyzer", "docs",
    }

    # Scan root and immediate subdirectories
    dirs_to_scan = [root]
    if scan_depth >= 1:
        for child in sorted(root.iterdir()):
            if child.is_dir() and child.name not in skip_dirs and not child.name.startswith("."):
                dirs_to_scan.append(child)
                if scan_depth >= 2:
                    for grandchild in sorted(child.iterdir()):
                        if grandchild.is_dir() and grandchild.name not in skip_dirs:
                            dirs_to_scan.append(grandchild)

    # Also discover Maven reactor sub-modules from pom.xml files
    # This ensures sub-module directories are always scanned, even if they are
    # deeper than scan_depth or in unusual paths declared in <modules>
    reactor_extra_dirs = []
    for d in dirs_to_scan:
        pom_file = d / "pom.xml"
        if pom_file.is_file():
            pom_content = _read_text(pom_file)
            declared_modules = _extract_xml_modules(pom_content)
            for mod_path in declared_modules:
                mod_dir = (d / mod_path).resolve()
                if mod_dir.is_dir() and mod_dir not in dirs_to_scan:
                    reactor_extra_dirs.append(mod_dir)
                    # Also scan sub-sub-modules (nested reactors, one level deep)
                    nested_pom = mod_dir / "pom.xml"
                    if nested_pom.is_file():
                        nested_content = _read_text(nested_pom)
                        nested_modules = _extract_xml_modules(nested_content)
                        for nested_path in nested_modules:
                            nested_dir = (mod_dir / nested_path).resolve()
                            if nested_dir.is_dir() and nested_dir not in dirs_to_scan:
                                reactor_extra_dirs.append(nested_dir)

    dirs_to_scan.extend(reactor_extra_dirs)

    seen_paths = set()
    for d in dirs_to_scan:
        for detector in DETECTORS:
            module = detector(d)
            if module and module.path not in seen_paths:
                seen_paths.add(module.path)
                # Make path relative to root for readability
                # Always use forward slashes (POSIX) so paths work in Docker/Linux
                try:
                    module.path = Path(module.path).relative_to(root).as_posix()
                except ValueError:
                    module.path = module.path.replace("\\", "/")
                if module.path == ".":
                    module.path = ""
                result.modules.append(module)

    # Deduce top-level info
    langs = sorted(set(m.language for m in result.modules))
    result.languages = langs

    # Creedengo plugins needed
    plugin_keys = sorted(set(
        _lang_to_creedengo_key(m.language)
        for m in result.modules
        if _lang_to_creedengo_key(m.language)
    ))
    result.creedengo_plugins = plugin_keys

    # Primary language = the one with most modules, prefer backend
    if result.modules:
        # Heuristic: prefer java > csharp > python > javascript
        priority = {"java": 0, "csharp": 1, "python": 2, "typescript": 3, "javascript": 4}
        primary = sorted(result.modules, key=lambda m: priority.get(m.language, 99))[0]
        result.primary_language = primary.language
        result.primary_framework = primary.framework

        # Determine scanner
        if any(m.build_tool == "maven" for m in result.modules):
            result.sonar_scanner = "maven"
        elif any(m.build_tool == "gradle" for m in result.modules):
            result.sonar_scanner = "gradle"
        else:
            result.sonar_scanner = "sonar-scanner"

        # Project key: prefer the reactor/parent POM name so all modules
        # are analyzed under a single SonarQube project key.
        reactor = next((m for m in result.modules if m.is_reactor), None)
        if reactor:
            result.project_key = reactor.name or root.name
        else:
            result.project_key = primary.name or root.name

    return result


def get_plugin_download_urls(plugin_key: str, version: str) -> list[str]:
    """Generate ordered list of download URLs to try for a given plugin."""
    info = CREEDENGO_PLUGINS.get(plugin_key)
    if not info:
        return []

    base = "https://github.com/green-code-initiative"
    artifact = info["artifact"].format(version=version)
    legacy_artifact = info["legacy_artifact"].format(version=version)

    return [
        f"{base}/{info['repo']}/releases/download/{version}/{artifact}",
        f"{base}/{info['repo']}/releases/download/v{version}/{artifact}",
        f"{base}/{info['legacy_repo']}/releases/download/{version}/{legacy_artifact}",
        f"{base}/{info['legacy_repo']}/releases/download/v{version}/{legacy_artifact}",
    ]


def format_summary(detection: StackDetection) -> str:
    """Format a human-readable summary."""
    lines = []
    lines.append("🌱 Creedengo Stack Detection")
    lines.append("=" * 40)
    lines.append(f"  Project root: {detection.project_root}")
    lines.append(f"  Languages:    {', '.join(detection.languages) or 'none'}")
    lines.append(f"  Primary:      {detection.primary_language} ({detection.primary_framework or 'no framework'})")
    lines.append(f"  Scanner:      {detection.sonar_scanner}")
    lines.append(f"  Plugins:      {', '.join(detection.creedengo_plugins) or 'none'}")
    lines.append("")

    for i, m in enumerate(detection.modules):
        fw = f" ({m.framework} {m.framework_version})" if m.framework else ""
        ver = f" v{m.language_version}" if m.language_version else ""
        reactor_tag = " [REACTOR]" if m.is_reactor else ""
        lines.append(f"  📦 [{i+1}] {m.name}{reactor_tag}")
        lines.append(f"       path:      {m.path or '.'}")
        lines.append(f"       language:  {m.language}{ver}")
        lines.append(f"       build:     {m.build_tool} ({m.config_file})")
        if fw:
            lines.append(f"       framework: {m.framework} {m.framework_version}")
        if m.sources_dir:
            lines.append(f"       sources:   {m.sources_dir}")
        if m.sub_modules:
            lines.append(f"       modules:   {', '.join(m.sub_modules)}")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Detect project stack for Creedengo")
    parser.add_argument("project", nargs="?", default=".", help="Project root directory")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--depth", type=int, default=2, help="Directory scan depth (default: 2)")
    args = parser.parse_args()

    detection = detect_stack(args.project, scan_depth=args.depth)

    if args.json:
        # Convert to JSON-serializable dict
        output = {
            "project_root": detection.project_root,
            "languages": detection.languages,
            "primary_language": detection.primary_language,
            "primary_framework": detection.primary_framework,
            "creedengo_plugins": detection.creedengo_plugins,
            "sonar_scanner": detection.sonar_scanner,
            "project_key": detection.project_key,
            "modules": [asdict(m) for m in detection.modules],
            "plugin_catalog": {
                k: {
                    **v,
                    "download_urls": get_plugin_download_urls(k, "1.7.0"),
                }
                for k, v in CREEDENGO_PLUGINS.items()
                if k in detection.creedengo_plugins
            },
        }
        print(json.dumps(output, indent=2))
    else:
        print(format_summary(detection))

    return 0 if detection.modules else 1


if __name__ == "__main__":
    raise SystemExit(main())

