/**
 * Stage 1 -- lint/unit, then the image build.
 *
 * TWO SECTIONS, BECAUSE THIS REPOSITORY HAS ONLY THE FIRST
 * ---------------------------------------------------------------------------
 * `gates` are the checks that gate a merge: each is one command in one pinned
 * container (or in the agent's own shell when it needs nothing but bash and
 * git). The root Jenkinsfile passes the same checks scripts/check.sh runs on
 * the laptop, so a green build means the same tools agreed on both machines.
 *
 * `image` is the artifact. An empty image means this repository produces no
 * container image -- boutique-platform is infrastructure, not a service -- and
 * the section says so in the log instead of silently succeeding.
 *
 * MULTI-ARCH
 * ---------------------------------------------------------------------------
 * `--platform a,b` only works with `push: true`: buildx's docker-container
 * driver has nowhere to put two architectures but a registry, and `--load`
 * moves exactly one. A multi-arch build without a push is therefore rejected
 * here rather than failing inside buildx with an error about drivers.
 *
 * @param opts.gates       List of [name:, command:, image:, dockerArgs:] --
 *                         image optional (absent = run in the agent shell),
 *                         dockerArgs optional (flags for the docker run)
 * @param opts.image       full image ref to build, "" for none
 * @param opts.dockerfile  default "Dockerfile"
 * @param opts.platforms   default "linux/amd64,linux/arm64"
 * @param opts.push        false = build into the local daemon only
 */
def call(Map opts = [:]) {
    def images = toolImages()
    List gates = opts.get('gates', [])
    String image = (opts.get('image', '') ?: '').toString()
    String dockerfile = opts.get('dockerfile', 'Dockerfile')
    String platforms = opts.get('platforms', 'linux/amd64,linux/arm64')
    boolean push = opts.get('push', false) as boolean

    gates.each { Map gate ->
        echo "gate: ${gate.name}"
        String gateImage = gate.image ?: null
        if (gateImage) {
            // dockerArgs lets a gate change how the container starts --
            // --entrypoint /bin/sh for the gate whose logic is a shell loop
            // (see resources/policy-fixtures.sh) -- without every gate
            // inheriting flags meant for one of them.
            String gateDockerArgs = (gate.dockerArgs ?: '') as String
            tools(gateImage, gate.command as String, gateDockerArgs ? [dockerArgs: gateDockerArgs] : [:])
        } else {
            // The agent's own shell: bash, git and coreutils, nothing more.
            sh(gate.command as String)
        }
    }

    if (!image) {
        echo 'build: skipped -- no image parameter. This repository has no'
        echo '       Dockerfile and produces no container artifact; a service'
        echo '       repo passes image: <ref> to build one.'
        return
    }

    if (!push && platforms.contains(',')) {
        error("build: platforms '${platforms}' with push: false cannot work -- "
            + 'buildx can only --load one architecture. Pass a single platform, '
            + 'or push: true to build the full matrix into a registry.')
    }

    container('dind') {
        String out = push ? '--push' : '--load'
        String plat = push ? "--platform ${platforms}" : ''
        sh """
            docker buildx create --name pipeline --driver docker-container --use >/dev/null 2>&1 \
              || docker buildx use pipeline
            docker buildx build ${plat} -f '${dockerfile}' -t '${image}' ${out} .
        """
    }
    echo "build: ${image}${push ? " (${platforms})" : ''}"
}
