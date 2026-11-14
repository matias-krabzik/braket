"""Integration checks for a stable, read-only version proposal across two repositories."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import publication_version_plan as release  # noqa: E402


class PublicationVersionPlanTests(unittest.TestCase):
    def git(self, root, *args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True,
                                       stderr=subprocess.DEVNULL).strip()

    def commit(self, root, message):
        self.git(root, "add", ".")
        self.git(root, "commit", "-m", message)

    def repo(self, path):
        path.mkdir()
        self.git(path, "init")
        self.git(path, "config", "user.name", "Test")
        self.git(path, "config", "user.email", "test@example.invalid")

    def test_proposal_is_stable_and_dirty_worktree_blocks_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            code, site = root / "code", root / "site"
            self.repo(code)
            self.repo(site)
            (code / "scripts").mkdir()
            (code / "scripts/generate_project.py").write_text(
                "MARKETING_VERSION = '0.5.7'\nBUILD_NUMBER = '47'\n")
            self.commit(code, "current code")
            head = self.git(code, "rev-parse", "HEAD")
            feed = site / "public/apps/krabzik-ide/appcast.xml"
            feed.parent.mkdir(parents=True)
            feed.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item><sparkle:shortVersionString>0.5.4</sparkle:shortVersionString>
<sparkle:version>14</sparkle:version></item></channel></rss>''')
            self.commit(site, "published catalog")
            profile = {"product": "Braket", "technology": "macos-swift",
                       "lastPublished": {"version": "0.5.4", "ref": head},
                       "versionBump": "patch",
                       "site": {"path": str(site),
                                "feed": "public/apps/krabzik-ide/appcast.xml"}}
            profile_path = root / "profile.json"
            profile_path.write_text(json.dumps(profile))
            initial_code = self.git(code, "status", "--porcelain")
            initial_site = self.git(site, "status", "--porcelain")
            input_payload = {"run": {"id": "run-1"},
                             "context": {"headCommit": head, "lastPublishedVersion": "0.5.4"}}
            first = release.plan(code, profile_path, input_payload)
            second = release.plan(code, profile_path, input_payload)
            self.assertEqual((first["proposedVersion"], first["proposedBuild"]), ("0.5.8", 48))
            self.assertEqual(first["status"], "ready")
            self.assertEqual(first, second)
            self.assertEqual(first["mutatedFiles"], [])
            self.assertEqual(self.git(code, "status", "--porcelain"), initial_code)
            self.assertEqual(self.git(site, "status", "--porcelain"), initial_site)
            (code / "scripts/generate_project.py").write_text(
                "MARKETING_VERSION = '0.5.7'\nBUILD_NUMBER = '47'\n# pending\n")
            blocked = release.plan(code, profile_path, input_payload)
            self.assertEqual(blocked["status"], "blocked")
            self.assertTrue(any("sin commit" in item for item in blocked["blockers"]))
            self.assertEqual((blocked["proposedVersion"], blocked["proposedBuild"]), ("0.5.8", 48))
            profile["versionBump"] = "minor"
            profile_path.write_text(json.dumps(profile))
            self.assertEqual(release.plan(code, profile_path, input_payload)["proposedVersion"], "0.6.0")


if __name__ == "__main__":
    unittest.main()
