# Partner Center Relationship Removal

## CSV

CSV-filen må inneholde:

```csv
WorkbookRow,Customer Name,TenantId
2,Eks Kunde,11111111-2222-3333-4444-555555555555
```

`TenantId` er kundens Tenant ID / Microsoft ID fra Partner Center.

## Preview

Kjør kommandoen fra roten av `csp-access-setup`.

Kjør `.\AdminRelationship\Remove-PartnerRelationships.ps1 -CsvPath '.\AdminRelationship\customer.csv'`

```powershell
PS C:\path\to\csp-access-setup> .\AdminRelationship\Remove-PartnerRelationships.ps1 -CsvPath '.\AdminRelationship\customer.csv'
```

Preview:

Gjør ingen endringer.

Krever ikke access token.

Lager en `RelationshipRemoval-*.csv` rapport.

En godkjent rad vil vise:

```text
Mode: Preview
Status: Preview
Details: No API request sent
```

## Execute

Kjør kommandoene fra roten av `csp-access-setup`.

Sett Partner Center access token. Kjør `$env:PARTNER_CENTER_ACCESS_TOKEN = 'ACCESS_TOKEN'`

```powershell
PS C:\path\to\csp-access-setup> $env:PARTNER_CENTER_ACCESS_TOKEN = 'ACCESS_TOKEN'
```

Kjør `.\AdminRelationship\Remove-PartnerRelationships.ps1 -CsvPath '.\AdminRelationship\customer.csv' -Execute`

```powershell
PS C:\path\to\csp-access-setup> .\AdminRelationship\Remove-PartnerRelationships.ps1 -CsvPath '.\AdminRelationship\customer.csv' -Execute
```

Scriptet viser hvor mange tenants som skal behandles.

Hvis CSV-en inneholder 1 tenant:

```text
Type REMOVE 1 to proceed
```

Bekreft med:

```text
REMOVE 1
```

Ved vellykket kjøring vil rapporten vise:

```text
Mode: Execute
Status: Success
Details: Reseller relationship removed
```

## Viktig

Kjør alltid Preview før Execute.

CSV-en bør kun inneholde tenantene som skal behandles i den aktuelle kjøringen.

Scriptet husker ikke hvilke tenants som er behandlet tidligere.

Access token er kun nødvendig ved `-Execute`.