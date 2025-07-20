{
  "subject": {
    "commonName": {{ toJson (coalesce .Insecure.User.commonName
                                .Insecure.CR.Subject.CommonName
                                         (first .SANs)) }},
    "organizationalUnit": {{ toJson .OrganizationalUnit }},
    "organization": {{ toJson .Organization }},
    "locality": {{ toJson .Locality }},
    "province": {{ toJson .Province }},
    "country": {{ toJson .Country }}
  },
  "sans": {{ toJson .SANs }},
  "keyUsage": [
    "digitalSignature"
  ],
  "extKeyUsage": [
{{- if not .Insecure.User.clientAuth }}
    "serverAuth",
{{- end }}
    "clientAuth"
  ]
}
