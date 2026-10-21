# Vendored Terraform modules

`main.tf` and `identity.tf` load these local copies instead of the Terraform Registry:

| Directory | Registry module | Tag | Commit |
| --- | --- | --- | --- |
| `vpc` | `terraform-aws-modules/vpc/aws` | `v5.21.0` | `7c1f791efd61f326ed6102d564d1a65d1eceedf0` |
| `eks` | `terraform-aws-modules/eks/aws` | `v20.37.2` | `8a0efdbbc84180a26e0bacfd2b6fcfceac53b3b6` |
| `rds` | `terraform-aws-modules/rds/aws` | `v6.12.0` | `22b02b391e1164cc1805e8f27eb4e3a5bd79bb95` |
| `iam` | `terraform-aws-modules/iam/aws` | `v5.59.0` | `0792d7f2753c265e3d610a58348fa1c551cbe4b8` |

These are the versions that were on the module blocks before the sources were switched to `./vendor/*`. IAM is included because `identity.tf` loads `./vendor/iam//modules/iam-role-for-service-accounts-eks`. Upstream examples, tests, docs, terragrunt wrappers, and `.github` workflows are not copied; Terraform does not load them for this stack.

Refresh after changing a pin in `scripts/vendor-terraform-modules.sh`:

```bash
./scripts/vendor-terraform-modules.sh
```

The script checks each tag out at the commit above and rewrites `PINS`.

`terraform init` still downloads the provider plugins pinned in `.terraform.lock.hcl` and the EKS module's nested registry module `terraform-aws-modules/kms/aws` version `2.1.0`. That nested source is part of the upstream EKS module and is left unchanged.
