/**
 * Stage 5 -- canary, burn-rate check, automatic rollback.
 *
 * The stage runs resources/canary.sh and does nothing clever itself: the
 * decision to put traffic back and undo the rollout has to be one uninterrupted
 * path through a shell script, not a Groovy branch that a later refactor can
 * accidentally gate behind an approval.
 *
 * WHAT IT NEEDS FROM THE APPLICATION, AND WHY THAT IS THE RIGHT SHAPE
 * ---------------------------------------------------------------------------
 * Three things this repository does not have, because it is not the application:
 *
 *   a Traefik weighted service splitting traffic between two Kubernetes
 *     Services. Traefik is installed (cluster/traefik) and its CRDs support
 *     this; the object belongs with the app's manifests, not with the pipeline.
 *   two Deployments/Services, stable and canary
 *   a PromQL expression whose value the gate compares against a threshold --
 *     a p99 latency, or an error ratio, whichever the service promises
 *
 * Every one of them is a required parameter. Missing any fails before the
 * traffic is shifted, not after.
 *
 * @param opts.namespace       where the canary lives (default boutique)
 * @param opts.deployment      canary Deployment name, for rollout undo
 * @param opts.traefikService  traefik.io WeightedService object name
 * @param opts.stableService   Service that carries the current release
 * @param opts.canaryService   Service that carries the candidate
 * @param opts.prometheusUrl   base URL of Prometheus, e.g. http://<svc>.observability:9090
 * @param opts.burnQuery       PromQL returning a vector
 * @param opts.burnThreshold   breach when the sample is greater than this
 * @param opts.weight          percent onto the canary, default 10
 * @param opts.observeSeconds  default 300
 */
def call(Map opts = [:]) {
    def required = [
        deployment     : opts.get('deployment', null),
        traefikService : opts.get('traefikService', null),
        stableService  : opts.get('stableService', null),
        canaryService  : opts.get('canaryService', null),
        prometheusUrl  : opts.get('prometheusUrl', null),
        burnQuery      : opts.get('burnQuery', null),
    ]
    List missing = required.findAll { !it.value }.keySet()
    if (missing) {
        error("canary: missing ${missing.join(', ')}. The canary cannot guess "
            + 'which object it is splitting traffic across or which signal says '
            + 'it is unhealthy -- see the parameter list in this step.')
    }

    def images = toolImages()
    container('dind') {
        withEnv([
            "CANARY_NAMESPACE=${opts.get('namespace', 'boutique')}",
            "CANARY_DEPLOYMENT=${required.deployment}",
            "CANARY_TRAEFIK_SERVICE=${required.traefikService}",
            "STABLE_SERVICE=${required.stableService}",
            "CANARY_SERVICE=${required.canaryService}",
            "PROM_URL=${required.prometheusUrl}",
            "BURN_QUERY=${required.burnQuery}",
            "BURN_THRESHOLD=${opts.get('burnThreshold', 0)}",
            "WEIGHT=${opts.get('weight', 10)}",
            "OBSERVE_SECONDS=${opts.get('observeSeconds', 300)}",
            "KUBECTL_IMAGE=${images.kubectl}",
            "CURL_IMAGE=${images.curl}",
        ]) {
            int status = sh(script: libraryResource('canary.sh'), returnStatus: true)
            if (status != 0) {
                error('canary: rolled back -- the burn-rate check breached, or '
                    + 'Prometheus could not answer, and the canary traffic was '
                    + 'shifted back automatically. See the log above.')
            }
        }
    }
}
