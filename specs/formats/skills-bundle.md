# App skills bundles (`.skillsbundle`)

Status: **planned** for Ycode 2 (Xcode 27.2 parity). Nothing is implemented yet. This spec records what
Apple's public documentation says, so that the work can start from it, and lists what still has to be
observed.

App skills are part of the Siri AI Developer Preview. Apple says the App Intents API and Siri behaviour may
change during the preview, so every fact below needs checking against the documentation when work starts.

## 1. What an app skill is

An app skill is a Markdown file that tells Siri how an app's tool intents fit together for a task that needs
several of them: which intent to use for which step, which to prefer when several could apply, what to
avoid, and knowledge specific to the app. Skills are guidance, not a program: Siri does not run the listed
intents in order, and a skill cannot make behaviour deterministic.

## 2. The bundle

- A target has at most **one** skills bundle. Xcode's template names it `Skills.skillsbundle`.
- The bundle holds one folder, `Skills/`. Each folder inside `Skills/` is one skill and contains exactly one
  file, `SKILL.md`. No other files are allowed in the bundle.
- A skill folder's name uses only lowercase letters, digits and hyphens.
- Skill names must be unique across the app, its extensions and its embedded frameworks. With duplicates, the
  system uses one of them, and which one is undefined.
- The bundle is a member of the app target's **Copy Bundle Resources** phase. If it isn't, or if it has
  errors at build time, the app provides no skills.

```
Skills.skillsbundle/
└── Skills/
    ├── <skill-name>/
    │   └── SKILL.md
    └── <other-skill-name>/
        └── SKILL.md
```

## 3. `SKILL.md`

- A front-matter block between two `---` lines, with exactly two fields:
  - `name`: the skill's name;
  - `description`: what the skill handles. Siri matches requests against it before reading the body.
- Then a Markdown body of free-form instructions, at most **10,000 characters**.
- This is a subset of the open Agent Skills format (agentskills.io): other front-matter fields and supporting
  files such as scripts or references are not supported.
- Apple's guidance for the body: refer to intents, parameters and entities by what they do, not by type name;
  don't repeat what the App Intents metadata already says.

## 4. Build

Xcode validates the bundle at build time and compiles it into the app bundle. On a supported device the
system indexes the compiled skills of the app, its extensions and its embedded frameworks.

## 5. What Ycode must do

1. **Project files:** recognise `.skillsbundle` as a file type that the Project navigator shows as one item
   that expands; File ▸ New ▸ File from Template ▸ Resource ▸ Skills Bundle, which suggests the name
   `Skills`, adds the bundle to the chosen app target and to its Copy Bundle Resources phase, and refuses a
   second bundle in the same target.
2. **Validation, as live issues and build errors:** the rules in §2 and §3, including the front-matter
   fields, the folder name, the single `SKILL.md`, extra files, the body length, duplicate names across the
   app, its extensions and embedded frameworks, and a bundle missing from Copy Bundle Resources.
3. **Build:** produce the compiled form inside the app bundle, matching Xcode's output (open question Q1).
4. **Editor:** `SKILL.md` opens in the Markdown editor with the front matter checked as you type; the
   coding assistant can draft a skill from the target's App Intents.
5. **Testing:** Apple verifies skills on a device or through TestFlight, not in the Simulator. Siri
   Evaluations lets automated integration tests check Siri's handling; supporting those test targets in
   `ycodebuild` is open question Q2.

Ycode's coding assistant already writes a `SKILL.md` for coding agents (`specs/ide/coding-assistant.md`
§10.6), in the full Agent Skills format. App skills are a different, smaller subset, so the two validators
stay separate.

## 6. Open questions (for observation)

- **Q1.** What Xcode writes into the app bundle for a skills bundle (path, format, whether it is the Markdown
  as-is or compiled), and which build tool and build settings are involved. Level 3: build a sample with
  `xcodebuild` and compare the products.
- **Q2.** How Siri Evaluations tests are declared and run (target type, scheme test action, command-line
  flags).
- **Q3.** The exact validation messages and whether each rule is an error or a warning.
- **Q4.** How the pbxproj records the bundle (file type identifier, last-known file type).

## Evidence

| Claim | Evidence | Level |
|---|---|---|
| §1–§4, §5 testing note | Apple, "Orchestrating complex actions with app skills" (App Intents documentation, developer.apple.com), read 2026-11-03 | 1 |
| The format is a subset of Agent Skills | The same page, citing agentskills.io's specification | 1 |
| §5 items 1–4 | Ycode's design, derived from §2–§4 | – |
