/**
 * Stage 4 -- the smoke gate.
 *
 * Zero errors, and a latency ceiling. Both are gates, not observations: the
 * script exits non-zero and the pipeline stops there, which is the difference
 * between this and a dashboard.
 *
 * The logic lives in resources/smoke.sh rather than in Groovy because it is a
 * shell script that deserves shellcheck, and scripts/check.sh shellchecks
 * every .sh in pipelines/resources/ on every run.
 *
 * @param opts.url         required: the endpoint to probe
 * @param opts.samples     default 20
 * @param opts.latencyMs   ceiling per sample, default 500
 * @param opts.namespace   only used for the log line (default boutique)
 */
def call(Map opts = [:]) {
    String url = (opts.get('url', '') ?: '').toString()
    String samples = opts.get('samples', 20)
    String latencyMs = opts.get('latencyMs', 500)
    String namespace = opts.get('namespace', 'boutique')

    if (!url) {
        error('smoke: no url. Pass the service the deploy just changed -- the '
            + 'gate cannot guess which endpoint the build is responsible for.')
    }

    def images = toolImages()
    container('dind') {
        withEnv([
            "SMOKE_URL=${url}",
            "SAMPLES=${samples}",
            "LATENCY_MS=${latencyMs}",
            "SMOKE_CURL_IMAGE=${images.curl}",
            "SMOKE_NAMESPACE=${namespace}",
        ]) {
            int status = sh(script: libraryResource('smoke.sh'), returnStatus: true)
            if (status != 0) {
                error("smoke: ${samples} samples against ${url} did not all pass "
                    + 'within the error budget and latency ceiling; the deploy is '
                    + 'not done.')
            }
        }
    }
}
