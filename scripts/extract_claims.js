const fs = require('fs');

const summaryPath = process.argv[2];
const outputPath = process.argv[3] || './trial_logs/extracted_claims.json';

if (!summaryPath) {
  console.error("Usage: node extract_claims.js <path_to_summary.txt> [output_path]");
  process.exit(1);
}

const summary = fs.readFileSync(summaryPath, 'utf-8');

const prompt = `Extract every discrete factual claim from this agent summary into JSON.
Categorize each as one of: "file_modified", "test_run", "test_result", "behavioral_assertion", "git_state".
Use "git_state" for any claim about commits, commit messages, commit authorship, push/pull status, branch state, or git history — not "behavioral_assertion".
Return ONLY the JSON array, no preamble, no markdown fences:
[{"claim": "...", "type": "...", "target": "..."}]

Summary:
${summary}`;

async function main() {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    console.error("ERROR: ANTHROPIC_API_KEY environment variable not set.");
    process.exit(1);
  }

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01"
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      max_tokens: 8000,
      messages: [{ role: "user", content: prompt }]
    })
  });

  const data = await response.json();

  if (data.error) {
    console.error("API error:", data.error);
    process.exit(1);
  }

  const rawText = data.content.map(b => b.text || "").join("");
  const cleaned = rawText.replace(/```json|```/g, "").trim();

  let claims;
  try {
    claims = JSON.parse(cleaned);
  } catch (e) {
    console.error("Failed to parse JSON from model output:");
    console.error(rawText);
    process.exit(1);
  }

  fs.mkdirSync('./trial_logs', { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(claims, null, 2));
  console.log(`Extracted ${claims.length} claims to ${outputPath}`);
  console.log(JSON.stringify(claims, null, 2));
}

main();
