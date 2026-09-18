terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.0 is a hard floor, not a preference. cpu_options.nested_virtualization
      # does not exist before it, and without that there is no /dev/kvm even on a
      # supported instance type -- the nodes install cleanly and then cannot start
      # a single VM. Older providers fail with "Unsupported argument", which is
      # the right way to find out.
      version = ">= 6.0"
    }
  }
}
