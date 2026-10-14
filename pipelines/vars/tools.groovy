/**
 * Run one command in one pinned tool container, with the build workspace
 * mounted. The primitive every other step in this library is built on.
 *
 * WHY A CONTAINER AND NOT AN INSTALL STEP
 * ---------------------------------------------------------------------------
 * The agent is jenkins/inbound-agent: a JRE, a shell and git. Installing helm,
 * conftest and trivy into it at build time would make every pipeline run depend
 * on a download that can fail, change or be MITM'd, and would leave the agent
 * image carrying a toolchain nobody pins. Pulling a digest-less-but-pinned tag
 * through the agent's own dockerd is a smaller, inspectable dependency.
 *
 * WHY `container('dind')`
 * ---------------------------------------------------------------------------
 * Steps execute in the jnlp container by default and that container has no
 * docker CLI. The daemon, the CLI and -- crucially -- the same filesystem view
 * of the workspace live in the dind container, so every docker invocation in
 * this library happens inside `container('dind')`. The kubernetes plugin mounts
 * the workspace volume at the workingDir of every container in the pod, which
 * is what makes `$WORKSPACE` in the jnlp container the same path in the dind
 * container.
 *
 * `-u 0 -e HOME=/tmp`: tools are run as root inside their own container so an
 * image without a passwd entry for uid 1000 (helm, conftest) does not fail
 * trying to create a cache directory under a home it does not have, and so any
 * file the tool writes into the workspace is readable by the next step.
 *
 * @param image  registry/repo:tag, from vars/toolImages.groovy
 * @param command  the command to run INSIDE the container (not through a shell)
 * @param opts.mount  set false to leave the workspace unmounted (default true)
 * @param opts.stdin  a workspace-relative or absolute path to feed on stdin
 * @param opts.network  'host' for anything that must reach the cluster API
 * @param opts.dockerArgs  extra flags for the docker run itself (extra mounts,
 *                         environment), for callers that need more than the
 *                         workspace (see vars/kubectl.groovy)
 */
def call(String image, String command, Map opts = [:]) {
    boolean mount = opts.get('mount', true) != false
    String stdinPath = opts.get('stdin', null)
    String network = opts.get('network', null)
    String dockerArgs = opts.get('dockerArgs', '')

    container('dind') {
        String docker = 'docker run --rm -u 0 -e HOME=/tmp'
        if (network) {
            docker += " --network ${network}"
        }
        if (dockerArgs) {
            docker += " ${dockerArgs}"
        }
        if (mount) {
            // The daemon runs in the dind container, so a path it can see is a
            // path in the pod. The workspace is mounted there at the same
            // absolute location as in the jnlp container.
            String ws = env.WORKSPACE
            docker += " -v '${ws}:/work' -w /work"
        }
        if (stdinPath) {
            // A shell redirect happens in the dind container, whose working
            // directory is the container's own workingDir, not the job's
            // workspace -- so a relative path here would resolve somewhere
            // else. Resolve it against the workspace instead.
            String src = stdinPath.startsWith('/') ? stdinPath : "${env.WORKSPACE}/${stdinPath}"
            sh "${docker} -i ${image} ${command} < '${src}'"
        } else {
            sh "${docker} ${image} ${command}"
        }
    }
}
