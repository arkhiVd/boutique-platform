/**
 * kubectl, from inside an agent pod, against the in-cluster API server.
 *
 * HOW THE POD AUTHENTICATES WITHOUT A KUBECONFIG
 * ---------------------------------------------------------------------------
 * The agent pod mounts its projected ServiceAccount token at
 * /var/run/secrets/kubernetes.io/serviceaccount (every container in the pod
 * gets that mount, not just the jnlp one), and kubelet injects
 * KUBERNETES_SERVICE_HOST/PORT into every container as well. Those two things
 * are the whole of in-cluster configuration: kubectl reads them when there is
 * no KUBECONFIG, and falls back to the token and CA in that directory. So the
 * image below needs the mount and the two environment variables and nothing
 * else -- no Secret with a kubeconfig, no credentials written to disk.
 *
 * The identity is the agent ServiceAccount (ci/rbac/agent-serviceaccount.yaml)
 * and its rights are whatever ci/rbac/agent-deploy-rolebinding.yaml grants.
 *
 * @param args  kubectl arguments, as argv -- not a shell line: pipes and
 *              redirects do not survive into the container. Use tools() with a
 *              shell image if you need those.
 * @param stdinPath  a path to feed on stdin, for `kubectl apply -f -`
 */
def call(String args, String stdinPath = null) {
    tools(toolImages().kubectl, args, [
        network    : 'host',
        stdin      : stdinPath,
        dockerArgs : '-v /var/run/secrets/kubernetes.io/serviceaccount:/var/run/secrets/kubernetes.io/serviceaccount:ro'
                     + ' -e KUBERNETES_SERVICE_HOST -e KUBERNETES_SERVICE_PORT',
    ])
}
