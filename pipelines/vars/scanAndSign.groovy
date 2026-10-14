/**
 * Stage 2 -- scan, SBOM, sign, push. The order is the order that means
 * something: nothing reaches a registry that has not been scanned, and nothing
 * is signed that has not been scanned either.
 *
 * WHAT EACH PIECE FAILS ON
 * ---------------------------------------------------------------------------
 *   trivy config   misconfigurations in the manifests themselves
 *   trivy image    CVEs in the image, HIGH and CRITICAL only -- the threshold
 *                  ROADMAP Phase 8 names. `--exit-code 1` is what makes the
 *                  stage red instead of merely verbose.
 *   syft           a CycloneDX SBOM written next to the workspace, as a build
 *                  artifact. It is not attested to anything yet (no registry,
 *                  no transparency log) -- recorded in TASKS.md.
 *   cosign         signs the image reference. Skipped, loudly, when no key is
 *                  configured: cosign keyless needs an OIDC identity this
 *                  account does not have, and a key file in a workspace is not
 *                  a key anyone should trust. The parameter is a cosign key
 *                  reference (for example k8s://ci/cosign-key) resolved by
 *                  cosign itself.
 *   docker push    only with an explicit registryLogin command, because a push
 *                  that runs without credentials fails in a way that looks
 *                  like a network problem.
 *
 * @param opts.manifests      repo-relative directory to scan as config
 * @param opts.image          image ref to scan (built by buildAndTest)
 * @param opts.severity       default HIGH,CRITICAL
 * @param opts.sbom           output file name, default sbom.cdx.json
 * @param opts.cosignKey      cosign key reference; "" = skip with a reason
 * @param opts.push           push after signing
 * @param opts.registryLogin  shell command that logs docker in (ECR, etc.)
 * @param opts.trivySkipDirs  directories trivy should not read (e.g. the
 *                            vendored Helm subcharts under charts/, whose
 *                            findings nobody here can fix without forking the
 *                            chart upstream)
 * @param opts.trivyIgnorefile  repo-relative trivy ignore file. Every entry in
 *                            it carries the reason that finding stays, so the
 *                            trade-off is reviewable instead of implicit.
 */
def call(Map opts = [:]) {
    def images = toolImages()
    String image = (opts.get('image', '') ?: '').toString()
    String manifests = (opts.get('manifests', '') ?: '').toString()
    String cosignKey = (opts.get('cosignKey', '') ?: '').toString()
    String registryLogin = (opts.get('registryLogin', '') ?: '').toString()
    String trivySkipDirs = (opts.get('trivySkipDirs', '') ?: '').toString()
    String trivyIgnorefile = (opts.get('trivyIgnorefile', '') ?: '').toString()
    String severity = opts.get('severity', 'HIGH,CRITICAL')
    String sbom = opts.get('sbom', 'sbom.cdx.json')
    boolean push = opts.get('push', false) as boolean

    // tools() runs every container with the workspace as its working
    // directory, so a repo-relative path needs no rewriting to be readable
    // inside one -- and passing it unrewritten is what makes this command
    // IDENTICAL to the one scripts/check.sh runs on the laptop. That matters
    // more than it looks: trivy's --skip-dirs matches against paths computed
    // from the target string, so the same pattern excludes a directory when the
    // target is `ci` and quietly fails to when it is `/work/ci`. Pinning trivy
    // twice is only worth it if both copies see the same arguments.
    if (manifests) {
        String configFlags = ''
        if (trivySkipDirs) {
            configFlags += " --skip-dirs ${trivySkipDirs}"
        }
        if (trivyIgnorefile) {
            configFlags += " --ignorefile '${trivyIgnorefile}'"
        }
        echo "scan: trivy config --severity ${severity} ${manifests}"
        tools(images.trivy, "config --exit-code 1 --severity ${severity}${configFlags} '${manifests}'")
    }

    if (!image) {
        echo 'scan: no image parameter -- manifest scan only.'
        echo '      This repository builds no container artifact; a service repo'
        echo '      passes the image ref buildAndTest produced.'
        return
    }

    tools(images.trivy, "image --exit-code 1 --severity ${severity} '${image}'")
    echo 'sbom: writing cyclonedx to the workspace'
    tools(images.syft, "'${image}' -q -o cyclonedx-json=/work/${sbom}")

    if (cosignKey) {
        tools(images.cosign, "sign --key ${cosignKey} '${image}'", [
            network   : 'host',
            dockerArgs: '-v /var/run/secrets/kubernetes.io/serviceaccount:/var/run/secrets/kubernetes.io/serviceaccount:ro'
                        + ' -e KUBERNETES_SERVICE_HOST -e KUBERNETES_SERVICE_PORT',
        ])
    } else {
        echo 'sign: SKIPPED -- no cosignKey parameter. Signing is wired but the'
        echo '      key does not exist yet: it is seeded out of band like the'
        echo '      other Secrets (see ci/jenkins/README.md) and until it is,'
        echo '      anything here would be an unsigned push wearing a green tick.'
        echo '      Tracked in TASKS.md.'
    }

    if (push) {
        if (!registryLogin) {
            echo 'push: SKIPPED -- push: true without a registryLogin command.'
            echo '      There is no registry in this account yet (no aws_ecr_repository'
            echo '      exists; see TASKS.md) and no AWS credential in Jenkins.'
            return
        }
        container('dind') {
            sh "${registryLogin} && docker push '${image}'"
        }
        echo "push: ${image}"
    }
}
