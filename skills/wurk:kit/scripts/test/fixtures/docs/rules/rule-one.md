# RULE-ONE (fixture)

A fake judged-text fixture for judge_test.rb, in the same deliberately fake
house style as the other fixtures (`zz` prefix, `faketool`, `docs/rules/`):
a step that states a decision in prose must not be handed to a script or
deleted rather than restated. Nothing here is a restatement of any real
rule - it exists only so judge_test.rb can drive a real `File.read` without
guessing at a real judged document's shape.
