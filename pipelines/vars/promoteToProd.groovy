/**
 * Stage 6 -- approval, then promote.
 *
 * The approval is the only human step in the pipeline and it is a gate, not a
 * notification: `input` blocks until someone in `submitter` clicks, and a run
 * that is denied stops the deploy. ROADMAP Phase 8's exit criterion is a
 * screenshot of that dialog plus a denied run -- both are produced by this
 * step, and neither is a script.
 *
 * @param opts.namespace    target namespace (default boutique)
 * @param opts.manifests    repo-relative directory of prod manifests to apply
 * @param opts.rollout      e.g. "deployment/frontend", for set image + status
 * @param opts.image        image ref to set on opts.rollout
 * @param opts.submitter    who may approve, default platform:admins (the same
 *                          group cluster/rbac/rbac.yaml grants cluster-admin to)
 * @param opts.timeoutMinutes  how long the input waits, default 30
 * @param opts.reason       what is being approved, shown in the dialog
 */
def call(Map opts = [:]) {
    String namespace = opts.get('namespace', 'boutique')
    String manifests = (opts.get('manifests', '') ?: '').toString()
    String rollout = (opts.get('rollout', '') ?: '').toString()
    String image = (opts.get('image', '') ?: '').toString()
    String submitter = opts.get('submitter', 'platform:admins')
    String reason = opts.get('reason', 'Promote this build to production')
    int timeoutMinutes = (opts.get('timeoutMinutes', 30)) as int

    if (!manifests && !rollout) {
        error('promote: nothing to promote -- pass manifests: <dir> and/or '
            + 'rollout: <kind/name>. Refusing to open an approval dialog that '
            + 'gates nothing.')
    }

    // Blocking, and the timeout matters: an input left open for a day is a
    // pipeline nobody can rerun and a release nobody can explain.
    input(
        message: reason,
        ok     : 'Promote',
        submitter: submitter,
        timeout: timeoutMinutes,
    )

    if (manifests) {
        String target = manifests.startsWith('/') ? "/work${manifests}" : "/work/${manifests}"
        kubectl("apply -f '${target}' -n ${namespace}")
    }
    if (image && rollout) {
        kubectl("set image ${rollout} ${image} -n ${namespace}")
    }
    if (rollout) {
        kubectl("rollout status ${rollout} -n ${namespace} --timeout=180s")
    }
    echo "promote: ${namespace} is on the approved build"
}
