config {
  # Inspect local modules (e.g. secrets/) for unused declarations and naming
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}
