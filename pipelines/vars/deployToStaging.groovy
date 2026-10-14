/**
 * Stage 3 -- deploy the build to the staging target.
 *
 * WHAT COUNTS AS "STAGING" HERE
 * ---------------------------------------------------------------------------
 * The namespace the pipeline deploys into, defaulting to `boutique`, because
 * that is the application namespace this repository has. The grant that lets it
 * do that is ci/rbac/agent-deploy-rolebinding.yaml -- the agent gets exactly
 * what a member of platform:developers gets, in that namespace only.
 *
 * Ephemeral `pr-<n>` namespaces are NOT implemented: a RoleBinding in
 * `boutique` does not create namespaces, and creating one per pull request is a
 * decision (who owns them, what quota, when they are reaped) that ROADMAP Phase
 * 8 leaves to the phase and TASKS.md records as open. Asking for a prNumber
 * fails with that sentence rather than applying to a namespace that does not
 * exist.
 *
 * @param opts.namespace  target namespace (default boutique)
 * @param opts.manifests  repo-relative directory of rendered YAML to apply
 * @param opts.image      image ref to set on opts.rollout, if any
 * @param opts.rollout    e.g. "deployment/frontend", for set image + status
 * @param opts.prNumber   fails: ephemeral namespaces are not provisioned yet
 */
def call(Map opts = [:]) {
    String namespace = opts.get('namespace', 'boutique')
    String manifests = (opts.get('manifests', '') ?: '').toString()
    String image = (opts.get('image', '') ?: '').toString()
    String rollout = (opts.get('rollout', '') ?: '').toString()
    def prNumber = opts.get('prNumber', null)

    if (prNumber) {
        error("deploy: pr-${prNumber} is not provisioned. Ephemeral preview "
            + 'namespaces need a grant outside boutique (see TASKS.md); they are '
            + 'not silently applied to a namespace that does not exist.')
    }

    if (manifests) {
        // kubectl runs in a container that only sees the workspace, mounted at
        // /work -- so a repo-relative path has to be rewritten for it.
        String target = manifests.startsWith('/') ? "/work${manifests}" : "/work/${manifests}"
        echo "deploy: kubectl apply -f ${target} -n ${namespace}"
        kubectl("apply -f '${target}' -n ${namespace}")
    }

    if (image && rollout) {
        kubectl("set image ${rollout} ${image} -n ${namespace}")
    }

    if (rollout) {
        // `rollout status` is the deployment gate: it does not return until
        // every replica is updated and available, or the timeout expires. A
        // deploy that returns while half the pods are still starting is how a
        // smoke gate ends up measuring the old version.
        kubectl("rollout status ${rollout} -n ${namespace} --timeout=180s")
    }

    if (!manifests && !rollout) {
        error('deploy: nothing to do -- pass manifests: <dir> and/or '
            + 'rollout: <kind/name>. Refusing to report a deploy that applied '
            + 'nothing.')
    }
}
