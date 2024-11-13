# Kubernetes GitOps

## Bootstrap

This cluster relies on ArgoCd for GitOps, initial installation is done via helm chart.

The file `argocd.values.yaml` contains the values required for this installation and its upgrades.
To manage all the applications an apps-in-app pattern is followed, the seed for this pattern is deployed with the argocd chart as defined in the `extraObjects` field.

```bash
helm upgrade argocd argo/argo-cd -f argocd.values.yaml --install --namespace argocd --create-namespace
```
