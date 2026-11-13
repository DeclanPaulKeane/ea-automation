-- EA custom policy: stamps a response header (and the upstream request) so you can see the policy ran. Easy showcase.
return {
  name = "ea-stamp",
  fields = {
    { config = {
        type = "record",
        fields = {
          { header_name  = { type = "string", default = "X-EA-Policy" } },
          { header_value = { type = "string", default = "stamped-by-ea-gateway" } },
        },
    } },
  },
}
