# Dashboard Generator

Le fichier `index.html` est genere a partir du template `index.save.html` en embarquant le rapport JSON.

## Utilisation

Depuis la racine du repo:

```bash
bash scripts/generate-dashboard.sh reports/latest-report.json dashboard/index.save.html dashboard/index.html
```

Sur Windows (PowerShell):

```powershell
.\scripts\generate-dashboard.ps1 reports\latest-report.json dashboard\index.save.html dashboard\index.html
```

Le dashboard reste fonctionnel meme sans rapport embarque: il tente de charger `reports/latest-report.json`.

