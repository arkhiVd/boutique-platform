/**
 * Every container image this library runs, in one place.
 *
 * A pipeline that says "we scan with trivy" without saying which trivy is
 * describing a moving target: the same Jenkinsfile can pass today and fail
 * tomorrow because a tag moved. Each tag below was checked against the
 * registry's own tag API before it was written here (Docker Hub / gcr.io,
 * 2026-10-14) and chosen to match the version this repository pins
 * elsewhere -- helm 3.16.3, conftest 0.68.0, gitleaks 8.30.1, actionlint
 * 1.7.11, shellcheck 0.11.0, trivy 0.69.3 are the same versions
 * scripts/check.sh runs on the laptop, so a green CI run means the same tools
 * agreed -- trivy in particular, whose misconfiguration checks grow between
 * releases: a newer image would fail CI on findings the laptop never had.
 *
 * Note the kubectl/cosign/trivy/syft/curl entries are not on the agent: the
 * agent image is jenkins/inbound-agent, which ships a JRE and nothing else.
 * They are pulled by the agent's dockerd on first use (see vars/tools.groovy)
 * and cached for the life of that pod, which is why the first build is the slow
 * one.
 */
def call() {
    return [
        helm      : 'alpine/helm:3.16.3',
        conftest  : 'openpolicyagent/conftest:v0.68.0',
        gitleaks  : 'zricethezav/gitleaks:v8.30.1',
        actionlint: 'rhysd/actionlint:1.7.11',
        shellcheck: 'koalaman/shellcheck:v0.11.0',
        // kubeconform: added 2026-10-15, after the first Jenkins run failed the
        // kubeconform gate with exit 127 ("-strict: not found"). The gate was
        // already in the Jenkinsfile with `image: images.kubeconform`, but
        // this map had no kubeconform key -- Groovy resolved `images.kubeconform`
        // to null, buildAndTest ran the gate with no container, and the agent's
        // own shell (which has no kubeconform) treated `-strict` as a command.
        // ghcr.io, not Docker Hub: the kubeconform author only publishes to
        // ghcr (verified with `docker manifest inspect` for v0.7.0, matching the
        // laptop's ~/.local/bin/kubeconform v0.7.0). Entrypoint is
        // /kubeconform, so the gate's command is its arguments.
        kubeconform: 'ghcr.io/yannh/kubeconform:v0.7.0',
        trivy     : 'aquasec/trivy:0.69.3',
        syft      : 'anchore/syft:v1.54.1',
        cosign    : 'gcr.io/projectsigstore/cosign:v3.1.3',
        kubectl   : 'rancher/kubectl:v1.36.2',
        curl      : 'curlimages/curl:8.22.0',
    ]
}
