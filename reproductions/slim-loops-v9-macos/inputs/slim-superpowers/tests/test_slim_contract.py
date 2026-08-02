import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SKILLS = {
    "brainstorming",
    "writing-plans",
    "systematic-debugging",
    "verification-before-completion",
}
REMOVED_SKILLS = {
    "using-superpowers",
    "dispatching-parallel-agents",
    "executing-plans",
    "finishing-a-development-branch",
    "receiving-code-review",
    "requesting-code-review",
    "subagent-driven-development",
    "test-driven-development",
    "using-git-worktrees",
    "writing-skills",
}


class SlimSuperpowersContractTest(unittest.TestCase):
    def test_only_four_scoped_skills_are_exposed(self) -> None:
        actual = {path.parent.name for path in (ROOT / "skills").glob("*/SKILL.md")}
        self.assertEqual(SKILLS, actual)

    def test_skill_prompt_budget_is_below_500_lines(self) -> None:
        total = sum(
            len((ROOT / "skills" / name / "SKILL.md").read_text().splitlines())
            for name in SKILLS
        )
        self.assertLessEqual(total, 500)

    def test_removed_workflows_are_not_runtime_dependencies(self) -> None:
        surfaces = [ROOT / "README.md", ROOT / ".codex-plugin" / "plugin.json"]
        surfaces.extend((ROOT / "skills" / name / "SKILL.md") for name in SKILLS)
        text = "\n".join(path.read_text() for path in surfaces)
        for name in REMOVED_SKILLS:
            self.assertNotIn(name, text)

    def test_non_codex_bootstraps_are_removed(self) -> None:
        for relative in ("hooks", ".claude-plugin", ".cursor-plugin", ".kimi-plugin", ".opencode", ".pi"):
            self.assertFalse((ROOT / relative).exists(), relative)

    def test_manifest_describes_scoped_methods(self) -> None:
        manifest = json.loads((ROOT / ".codex-plugin" / "plugin.json").read_text())
        self.assertEqual("superpowers", manifest["name"])
        self.assertIn("scoped", manifest["description"].lower())
        self.assertNotIn("TDD", manifest["interface"]["longDescription"])

    def test_trigger_boundaries_are_explicit(self) -> None:
        brainstorming = (ROOT / "skills" / "brainstorming" / "SKILL.md").read_text().lower()
        planning = (ROOT / "skills" / "writing-plans" / "SKILL.md").read_text()
        debugging = (ROOT / "skills" / "systematic-debugging" / "SKILL.md").read_text().lower()
        verification = (ROOT / "skills" / "verification-before-completion" / "SKILL.md").read_text().lower()

        self.assertIn("code research", brainstorming)
        self.assertIn("plan", brainstorming)
        self.assertIn("Global Constraints", planning)
        self.assertIn("Interfaces", planning)
        self.assertIn("root cause", debugging)
        self.assertIn("fresh evidence", verification)


if __name__ == "__main__":
    unittest.main()
