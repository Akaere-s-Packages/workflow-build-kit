#!/usr/bin/env python3
"""Regression tests for package-detail website data generation."""
import importlib.util
from unittest.mock import patch
import pathlib
import unittest


GEN_DATA_PATH = pathlib.Path(__file__).parents[2] / "scripts" / "website" / "gen_data.py"
SPEC = importlib.util.spec_from_file_location("gen_data", GEN_DATA_PATH)
gen_data = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(gen_data)


class ParseSourcesTests(unittest.TestCase):
    def test_parses_remote_and_local_srcinfo_sources(self):
        srcinfo = """\
pkgbase = example
	source = release.tar.gz::https://example.test/releases/release.tar.gz
	source = git+https://github.com/example/project.git#tag=v1.2.3
	source = local.patch
	source_x86_64 = https://example.test/x86_64.tar.xz
"""
        self.assertEqual(
            gen_data.parse_sources(srcinfo),
            [
                {"name": "release.tar.gz", "url": "https://example.test/releases/release.tar.gz"},
                {"name": "project.git", "url": "https://github.com/example/project.git#tag=v1.2.3"},
                {"name": "local.patch"},
                {"name": "x86_64.tar.xz", "url": "https://example.test/x86_64.tar.xz"},
            ],
        )


if __name__ == "__main__":
    unittest.main()



class BuildDetailTests(unittest.TestCase):
    def test_refreshes_sources_from_the_pkgbase_srcinfo(self):
        entry = {
            "name": "example",
            "pkgbase": "example",
            "distro": "archlinux",
            "type": "aur",
            "version": "1.0-1",
        }
        existing = {"sources": [{"name": "stale.tar.gz", "url": "https://old.example/stale.tar.gz"}]}

        detail = gen_data.build_detail(
            entry,
            {},
            None,
            existing,
            [{"name": "release.tar.gz", "url": "https://example.test/release.tar.gz"}],
        )

        self.assertEqual(
            detail["sources"],
            [{"name": "release.tar.gz", "url": "https://example.test/release.tar.gz"}],
        )


class FetchSourcesTests(unittest.TestCase):
    def test_retains_existing_sources_when_srcinfo_lookup_fails(self):
        with (
            patch.object(gen_data.aur_graph, "RETRY_ATTEMPTS", 1),
            patch("urllib.request.urlopen", side_effect=OSError("connection reset")),
        ):
            self.assertIsNone(gen_data.fetch_srcinfo_sources("example"))