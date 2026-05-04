module.exports = async ({ github, context, core }) => {
  if (context.eventName !== "pull_request") {
    core.info(
      `Event is '${context.eventName}', not a pull request — skipping.`
    );
    return;
  }
  // Fetch current labels (payload labels are stale on re-runs)
  const { data: pr } = await github.rest.pulls.get({
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: context.issue.number,
  });
  const labels = pr.labels.map((l) => l.name);
  if (labels.includes("no changelog")) {
    core.info('PR has "no changelog" label — skipping changelog check.');
    return;
  }

  const { data: files } = await github.rest.pulls.listFiles({
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: context.issue.number,
    per_page: 100,
  });

  // Fail if CHANGELOG.md is modified directly
  const directEdits = files.filter(
    (f) =>
      (f.filename === "CHANGELOG.md" ||
        f.filename === "stacks-signer/CHANGELOG.md") &&
      f.status === "modified"
  );

  if (directEdits.length > 0) {
    const edited = directEdits.map((f) => f.filename).join(", ");
    core.setFailed(
      `Do not edit ${edited} directly. ` +
        "Add a changelog fragment to changelog.d/ or stacks-signer/changelog.d/ instead " +
        "(see changelog.d/README.md for instructions)."
    );
    return;
  }

  const validExtensions = ["added", "changed", "fixed", "removed"];
  const filenamePattern = /^\d+-[a-z0-9-]+$/;

  function isValidFragmentName(filename) {
    const baseName = filename.split("/").pop();
    const nameWithoutExt = baseName.slice(0, baseName.lastIndexOf("."));
    return filenamePattern.test(nameWithoutExt);
  }

  const fragments = files.filter((f) => {
    const isInValidDir =
      f.filename.startsWith("changelog.d/") ||
      f.filename.startsWith("stacks-signer/changelog.d/");
    const hasValidExt = validExtensions.some((ext) =>
      f.filename.endsWith(`.${ext}`)
    );
    const isAdded = f.status === "added";
    const isValidName = isValidFragmentName(f.filename);

    if (isInValidDir && hasValidExt && isAdded && !isValidName) {
      core.setFailed(
        `Invalid changelog filename '${f.filename}': ` +
          `must match pattern '<PR#>-<short-description>.<category>' ` +
          `(example: '6811-marf-compress.added')`
      );
    }

    return isInValidDir && hasValidExt && isAdded && isValidName;
  });

  if (fragments.length === 0) {
    core.setFailed(
      "No changelog fragment found. Please add a fragment file to changelog.d/ " +
        "or stacks-signer/changelog.d/ (see changelog.d/README.md for instructions). " +
        'If no changelog entry is needed, add the "no changelog" label to the PR.'
    );
  } else {
    const names = fragments.map((f) => f.filename).join(", ");
    core.info(`Found changelog fragment(s): ${names}`);
  }
};
