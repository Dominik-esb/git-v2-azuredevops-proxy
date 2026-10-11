# Upgrading to 2.0 (non-root)

Version 2.0 runs the container as an unprivileged user (uid/gid `10001`) and listens on **8080**
instead of 80. Images up to 1.x ran as root on port 80. Existing deployments stop working until
both steps below are done.

- **Port.** The container port is now `8080`. Change port mappings such as `7080:80` to
  `7080:8080`, and a Kubernetes Service's `targetPort` to `8080` (or the port name `http`). The
  Service itself can keep port `80`, so in-cluster URLs don't change. Setting `HTTP_PORT=80` back works only where the
  container runtime lets unprivileged processes bind low ports; 8080 does not depend on it.
- **Existing `/repos` volume.** Files the old image wrote are owned by root, and the proxy refuses
  to start with a message saying so. Fix the ownership once:
  - **Docker:**

    ```bash
    docker run --rm -u 0 -v <volume>:/repos --entrypoint chown <image> -R 10001:10001 /repos
    ```

  - **Kubernetes:** scale the Deployment to 0 and run one root pod on the PVC. It needs a
    namespace that allows it, because the pod is deliberately not `restricted`:

    ```bash
    kubectl -n git-proxy scale deploy/git-proxy --replicas=0
    kubectl -n git-proxy run fix-owner --rm -it --restart=Never --image=busybox --overrides='
      {"spec":{"containers":[{"name":"fix-owner","image":"busybox",
        "command":["chown","-R","10001:10001","/repos"],
        "volumeMounts":[{"name":"r","mountPath":"/repos"}]}],
        "volumes":[{"name":"r","persistentVolumeClaim":{"claimName":"git-proxy-data"}}]}}'
    kubectl -n git-proxy scale deploy/git-proxy --replicas=1
    ```

    `fsGroup: 10001` in [`k8s/base`](../k8s/base/deployment.yaml) does **not** replace this. It
    changes a volume's group, not its owner, and the proxy needs to own its mirrors (it rewrites
    and `chmod`s their hooks, and git's `safe.directory` check can reject a repository owned by
    another user). What `fsGroup` does do is let the proxy create its mirror on a fresh PVC whose
    root belongs to root. It only works on storage that supports it — `hostPath`, k3s/kind
    `local-path` and most NFS ignore it, and the kubelet logs
    `The requested fsGroup is 10001, but the volume ... has GID 0`.
