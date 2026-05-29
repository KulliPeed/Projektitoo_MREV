#!/usr/bin/env python3
"""Configure Apache Superset for the MREV MART views via the REST API."""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote

import requests


PROJECT_DIR = Path("/home/pi/kool/projekt")
ENV_FILE = PROJECT_DIR / ".env.superset"
REPORT_DIR = PROJECT_DIR / "docs"

DEFAULT_SUPERSET_URL = "http://127.0.0.1:8088"
DEFAULT_DATABASE_NAME = "MREV andmeprojekt MART"
DASHBOARD_TITLE = "MREV maksuvõlg ja juhatuse muutused"

REQUIRED_ENV = (
    "SUPERSET_ADMIN_USERNAME",
    "SUPERSET_ADMIN_PASSWORD",
    "SUPERSET_READONLY_DB_USER",
    "SUPERSET_READONLY_DB_PASSWORD",
)

DATASETS = (
    "v_dashboard_kpi",
    "v_maksuvolg_vanusegruppide_kaupa",
    "v_maksuvolg_juhatuse_muutus_vanusegrupp",
    "v_top_maksuvolglased",
    "v_maksuvolglased_juhatuse_muutusega",
    "v_viimased_maksuvolglased_rik_andmetega",
)


class SupersetConfigError(RuntimeError):
    """Raised when the configuration cannot continue."""


@dataclass
class ApiResult:
    status: str
    detail: str
    object_id: int | None = None


@dataclass
class RunSummary:
    started_at: datetime
    superset_url: str
    superset_health: ApiResult | None = None
    login: ApiResult | None = None
    csrf: ApiResult | None = None
    database: ApiResult | None = None
    connection_test: ApiResult | None = None
    datasets: dict[str, ApiResult] = field(default_factory=dict)
    dataset_refresh: dict[str, ApiResult] = field(default_factory=dict)
    charts: dict[str, ApiResult] = field(default_factory=dict)
    dashboard: ApiResult | None = None
    dashboard_chart_link: ApiResult | None = None
    users: dict[str, ApiResult] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)


class SupersetClient:
    def __init__(self, base_url: str, secrets: list[str]) -> None:
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update({"Accept": "application/json"})
        self.secrets = [secret for secret in secrets if secret]
        self.csrf_token: str | None = None

    def sanitize(self, value: Any) -> str:
        text = str(value)
        for secret in self.secrets:
            text = text.replace(secret, "<redacted>")
        text = re.sub(
            r"(postgresql\+psycopg2://[^:\s]+:)[^@\s]+(@)",
            r"\1<redacted>\2",
            text,
        )
        return text

    def request(
        self,
        method: str,
        path: str,
        *,
        expected: tuple[int, ...] = (200,),
        json_payload: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
        use_csrf: bool = False,
    ) -> requests.Response:
        headers: dict[str, str] = {}
        if use_csrf and self.csrf_token:
            headers["X-CSRFToken"] = self.csrf_token

        response = self.session.request(
            method,
            f"{self.base_url}{path}",
            json=json_payload,
            params=params,
            headers=headers,
            timeout=60,
        )
        if response.status_code not in expected:
            body = response.text[:1200]
            raise SupersetConfigError(
                f"{method} {path} returned HTTP {response.status_code}: {self.sanitize(body)}"
            )
        return response

    def login(self, username: str, password: str) -> None:
        response = self.request(
            "POST",
            "/api/v1/security/login",
            expected=(200,),
            json_payload={
                "username": username,
                "password": password,
                "provider": "db",
                "refresh": True,
            },
        )
        payload = response.json()
        access_token = payload.get("access_token") or payload.get("result", {}).get("access_token")
        if not access_token:
            raise SupersetConfigError("Login response did not contain access_token")
        self.session.headers.update({"Authorization": f"Bearer {access_token}"})

    def fetch_csrf_token(self) -> None:
        response = self.request("GET", "/api/v1/security/csrf_token/", expected=(200,))
        payload = response.json()
        token = payload.get("result")
        if isinstance(token, dict):
            token = token.get("csrf_token")
        if not token:
            raise SupersetConfigError("CSRF response did not contain a token")
        self.csrf_token = str(token)

    def list_objects(self, path: str) -> list[dict[str, Any]]:
        response = self.request(
            "GET",
            path,
            expected=(200,),
            params={"page_size": 500},
        )
        payload = response.json()
        result = payload.get("result", [])
        if isinstance(result, dict):
            result = result.get("data", result.get("result", []))
        return result if isinstance(result, list) else []

    def post_json(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        response = self.request(
            "POST",
            path,
            expected=(200, 201),
            json_payload=payload,
            use_csrf=True,
        )
        return response.json()

    def put_json(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        response = self.request(
            "PUT",
            path,
            expected=(200,),
            json_payload=payload,
            use_csrf=True,
        )
        return response.json()


def load_dotenv(path: Path) -> None:
    if not path.exists():
        raise SupersetConfigError(f"Puudub {path}")

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if (
            len(value) >= 2
            and ((value[0] == value[-1] == '"') or (value[0] == value[-1] == "'"))
        ):
            value = value[1:-1]
        os.environ.setdefault(key, value)


def require_env() -> dict[str, str]:
    missing = [name for name in REQUIRED_ENV if not os.environ.get(name)]
    if missing:
        raise SupersetConfigError("Puuduvad kohustuslikud muutujad: " + ", ".join(missing))
    return {name: os.environ[name] for name in REQUIRED_ENV}


def object_id(payload: dict[str, Any]) -> int | None:
    for key in ("id", "pk"):
        value = payload.get(key)
        if isinstance(value, int):
            return value
    result = payload.get("result")
    if isinstance(result, dict):
        for key in ("id", "pk"):
            value = result.get(key)
            if isinstance(value, int):
                return value
    return None


def find_by_name(objects: list[dict[str, Any]], *fields: str, value: str) -> dict[str, Any] | None:
    for item in objects:
        for field_name in fields:
            if item.get(field_name) == value:
                return item
    return None


def database_uri(readonly_user: str, readonly_password: str) -> str:
    return (
        "postgresql+psycopg2://"
        f"{quote(readonly_user, safe='')}:{quote(readonly_password, safe='')}"
        "@andmeprojekt_postgres:5432/andmeprojekt"
    )


def ensure_database(
    client: SupersetClient,
    summary: RunSummary,
    database_name: str,
    readonly_user: str,
    readonly_password: str,
) -> int:
    existing = find_by_name(
        client.list_objects("/api/v1/database/"),
        "database_name",
        "database_name_text",
        value=database_name,
    )
    if existing:
        db_id = int(existing["id"])
        summary.database = ApiResult(
            "olemas",
            "Sama nimega database connection oli juba olemas; URI-d ei prinditud ega muudetud.",
            db_id,
        )
        return db_id

    payload = {
        "database_name": database_name,
        "sqlalchemy_uri": database_uri(readonly_user, readonly_password),
        "expose_in_sqllab": True,
        "allow_ctas": False,
        "allow_cvas": False,
        "allow_dml": False,
        "extra": json.dumps({"metadata_params": {}, "engine_params": {}, "metadata_cache_timeout": {}}),
    }
    created = client.post_json("/api/v1/database/", payload)
    db_id = object_id(created)
    if db_id is None:
        existing = find_by_name(client.list_objects("/api/v1/database/"), "database_name", value=database_name)
        if not existing:
            raise SupersetConfigError("Database connection loodi, aga ID-d ei õnnestunud tuvastada")
        db_id = int(existing["id"])
    summary.database = ApiResult("loodud", "Database connection loodi Superseti API kaudu.", db_id)
    return db_id


def try_connection_test(
    client: SupersetClient,
    summary: RunSummary,
    database_name: str,
    readonly_user: str,
    readonly_password: str,
) -> None:
    payload = {
        "database_name": database_name,
        "sqlalchemy_uri": database_uri(readonly_user, readonly_password),
        "engine": "postgresql",
    }
    try:
        client.post_json("/api/v1/database/test_connection/", payload)
    except Exception as exc:  # noqa: BLE001 - report unsupported endpoint without stopping.
        summary.connection_test = ApiResult(
            "vahele jäetud",
            "Superseti API ühenduse test ei olnud selles versioonis kasutatav: "
            + client.sanitize(exc),
        )
        return
    summary.connection_test = ApiResult("ok", "Superseti database test_connection endpoint õnnestus.")


def dataset_database_id(dataset: dict[str, Any]) -> int | None:
    database = dataset.get("database")
    if isinstance(database, dict):
        value = database.get("id")
        return int(value) if isinstance(value, int) else None
    if isinstance(database, int):
        return database
    value = dataset.get("database_id")
    return int(value) if isinstance(value, int) else None


def find_dataset(
    client: SupersetClient,
    db_id: int,
    schema: str,
    table_name: str,
) -> dict[str, Any] | None:
    for dataset in client.list_objects("/api/v1/dataset/"):
        if dataset.get("schema") != schema or dataset.get("table_name") != table_name:
            continue
        found_db_id = dataset_database_id(dataset)
        if found_db_id in (None, db_id):
            return dataset
    return None


def refresh_dataset(client: SupersetClient, summary: RunSummary, dataset_id: int, table_name: str) -> None:
    for method, path in (
        ("PUT", f"/api/v1/dataset/{dataset_id}/refresh"),
        ("POST", f"/api/v1/dataset/{dataset_id}/refresh"),
    ):
        try:
            if method == "PUT":
                client.put_json(path, {})
            else:
                client.post_json(path, {})
            summary.dataset_refresh[table_name] = ApiResult("ok", "Dataset columns refresh õnnestus.")
            return
        except Exception as exc:  # noqa: BLE001
            last_error = client.sanitize(exc)
    summary.dataset_refresh[table_name] = ApiResult(
        "vahele jäetud",
        "Dataset refresh endpoint ei olnud kasutatav: " + last_error,
    )


def ensure_datasets(client: SupersetClient, summary: RunSummary, db_id: int) -> dict[str, int]:
    dataset_ids: dict[str, int] = {}
    for table_name in DATASETS:
        existing = find_dataset(client, db_id, "mart", table_name)
        if existing:
            ds_id = int(existing["id"])
            summary.datasets[table_name] = ApiResult("olemas", "Dataset oli juba olemas.", ds_id)
            dataset_ids[table_name] = ds_id
            summary.dataset_refresh[table_name] = ApiResult(
                "vahele jäetud",
                "Dataset refresh jäeti vahele, sest see Superseti versioon proovib datetime detectoris schema nime PostgreSQL catalog'ina kasutada.",
                ds_id,
            )
            continue

        payload = {"database": db_id, "schema": "mart", "table_name": table_name}
        try:
            created = client.post_json("/api/v1/dataset/", payload)
            ds_id = object_id(created)
            if ds_id is None:
                existing = find_dataset(client, db_id, "mart", table_name)
                if not existing:
                    raise SupersetConfigError("Dataset loodi, aga ID-d ei õnnestunud tuvastada")
                ds_id = int(existing["id"])
            summary.datasets[table_name] = ApiResult("loodud", "Dataset loodi Superseti API kaudu.", ds_id)
            dataset_ids[table_name] = ds_id
            summary.dataset_refresh[table_name] = ApiResult(
                "vahele jäetud",
                "Dataset refresh jäeti vahele, sest see Superseti versioon proovib datetime detectoris schema nime PostgreSQL catalog'ina kasutada.",
                ds_id,
            )
        except Exception as exc:  # noqa: BLE001
            summary.datasets[table_name] = ApiResult(
                "ebaõnnestus",
                "Dataseti loomine API kaudu ebaõnnestus: " + client.sanitize(exc),
            )
    return dataset_ids


def adhoc_metric(column: str, label: str) -> dict[str, Any]:
    return {
        "aggregate": "SUM",
        "column": {"column_name": column},
        "expressionType": "SIMPLE",
        "hasCustomLabel": True,
        "label": label,
    }


def base_query(**overrides: Any) -> dict[str, Any]:
    query: dict[str, Any] = {
        "annotation_layers": [],
        "extras": {"where": "", "having": ""},
        "filters": [],
        "is_timeseries": False,
        "time_range": "No filter",
    }
    query.update(overrides)
    return query


def chart_payload(
    name: str,
    viz_type: str,
    dataset_id: int,
    params: dict[str, Any],
    query: dict[str, Any],
) -> dict[str, Any]:
    params = {"datasource": f"{dataset_id}__table", "viz_type": viz_type, **params}
    query_context = {
        "datasource": {"id": dataset_id, "type": "table"},
        "force": False,
        "queries": [query],
        "form_data": params,
        "result_format": "json",
        "result_type": "full",
    }
    return {
        "slice_name": name,
        "viz_type": viz_type,
        "datasource_id": dataset_id,
        "datasource_type": "table",
        "params": json.dumps(params, ensure_ascii=False),
        "query_context": json.dumps(query_context, ensure_ascii=False),
    }


def chart_definitions(dataset_ids: dict[str, int]) -> list[dict[str, Any]]:
    kpi_dataset = dataset_ids.get("v_dashboard_kpi")
    age_dataset = dataset_ids.get("v_maksuvolg_vanusegruppide_kaupa")
    top_dataset = dataset_ids.get("v_top_maksuvolglased")

    charts: list[dict[str, Any]] = []
    if kpi_dataset:
        for name, column, label in (
            ("MREV KPI - maksuvõlglaste arv", "mta_ettevotteid", "Maksuvõlglaste arv"),
            ("MREV KPI - maksuvõlg kokku", "maksuvolg_summa", "Maksuvõlg kokku"),
            (
                "MREV KPI - juhatuse muutusega maksuvõlglased",
                "juhatus_muutunud_ettevotteid",
                "Juhatuse muutusega maksuvõlglased",
            ),
        ):
            metric = adhoc_metric(column, label)
            charts.append(
                chart_payload(
                    name,
                    "big_number_total",
                    kpi_dataset,
                    {
                        "metric": metric,
                        "adhoc_filters": [],
                        "time_range": "No filter",
                        "y_axis_format": "SMART_NUMBER",
                    },
                    base_query(columns=[], metrics=[metric], row_limit=10000),
                )
            )
    if age_dataset:
        metric = adhoc_metric("maksuvolg_summa", "Maksuvõlg")
        charts.append(
            chart_payload(
                "MREV - maksuvõlg vanusegrupi kaupa",
                "dist_bar",
                age_dataset,
                {
                    "groupby": ["volg_vanuse_grupp"],
                    "metrics": [metric],
                    "adhoc_filters": [],
                    "time_range": "No filter",
                    "order_desc": True,
                    "row_limit": 10000,
                    "y_axis_format": "SMART_NUMBER",
                },
                base_query(columns=["volg_vanuse_grupp"], metrics=[metric], row_limit=10000),
            )
        )
    if top_dataset:
        columns = [
            "mta_data_as_of",
            "rik_snapshot_date",
            "registrikood",
            "nimi",
            "maksuvolg",
            "volg_vanuse_grupp",
            "juhatus_muutus",
            "lisatud_juhatuse_liikmeid",
            "eemaldatud_juhatuse_liikmeid",
            "leitud_rikist",
        ]
        charts.append(
            chart_payload(
                "MREV - top maksuvõlglased",
                "table",
                top_dataset,
                {
                    "query_mode": "raw",
                    "all_columns": columns,
                    "order_by_cols": ["[\"maksuvolg\", false]"],
                    "row_limit": 25,
                    "page_length": 25,
                    "time_range": "No filter",
                    "table_timestamp_format": "smart_date",
                },
                base_query(
                    columns=columns,
                    metrics=[],
                    orderby=[["maksuvolg", False]],
                    row_limit=25,
                ),
            )
        )
    return charts


def ensure_charts(client: SupersetClient, summary: RunSummary, dataset_ids: dict[str, int]) -> list[int]:
    chart_ids: list[int] = []
    existing_charts = client.list_objects("/api/v1/chart/")
    for payload in chart_definitions(dataset_ids):
        name = str(payload["slice_name"])
        existing = find_by_name(existing_charts, "slice_name", value=name)
        if existing:
            chart_id = int(existing["id"])
            try:
                client.put_json(f"/api/v1/chart/{chart_id}", payload)
                summary.charts[name] = ApiResult("olemas", "Chart oli juba olemas; query_context uuendati.", chart_id)
            except Exception as exc:  # noqa: BLE001
                summary.charts[name] = ApiResult(
                    "ebaõnnestus",
                    "Olemasoleva charti uuendamine API kaudu ebaõnnestus: " + client.sanitize(exc),
                    chart_id,
                )
            chart_ids.append(chart_id)
            continue

        try:
            created = client.post_json("/api/v1/chart/", payload)
            chart_id = object_id(created)
            if chart_id is None:
                existing = find_by_name(client.list_objects("/api/v1/chart/"), "slice_name", value=name)
                if not existing:
                    raise SupersetConfigError("Chart loodi, aga ID-d ei õnnestunud tuvastada")
                chart_id = int(existing["id"])
            summary.charts[name] = ApiResult("loodud", "Chart loodi Superseti API kaudu.", chart_id)
            chart_ids.append(chart_id)
        except Exception as exc:  # noqa: BLE001
            summary.charts[name] = ApiResult(
                "ebaõnnestus",
                "Charti loomine API kaudu ebaõnnestus: " + client.sanitize(exc),
            )
    return chart_ids

def ensure_dashboard(client: SupersetClient, summary: RunSummary, chart_ids: list[int]) -> None:
    existing = find_by_name(
        client.list_objects("/api/v1/dashboard/"),
        "dashboard_title",
        value=DASHBOARD_TITLE,
    )
    if existing:
        dashboard_id = int(existing["id"])
        summary.dashboard = ApiResult("olemas", "Dashboard oli juba olemas.", dashboard_id)
    else:
        try:
            created = client.post_json(
                "/api/v1/dashboard/",
                {
                    "dashboard_title": DASHBOARD_TITLE,
                    "slug": "mrev-maksuvolg-ja-juhatuse-muutused",
                    "published": True,
                },
            )
            dashboard_id = object_id(created)
            if dashboard_id is None:
                existing = find_by_name(
                    client.list_objects("/api/v1/dashboard/"),
                    "dashboard_title",
                    value=DASHBOARD_TITLE,
                )
                if not existing:
                    raise SupersetConfigError("Dashboard loodi, aga ID-d ei õnnestunud tuvastada")
                dashboard_id = int(existing["id"])
            summary.dashboard = ApiResult("loodud", "Dashboard loodi Superseti API kaudu.", dashboard_id)
        except Exception as exc:  # noqa: BLE001
            summary.dashboard = ApiResult(
                "ebaõnnestus",
                "Dashboardi loomine API kaudu ebaõnnestus: " + client.sanitize(exc),
            )
            return

    if not chart_ids or not summary.dashboard or summary.dashboard.object_id is None:
        summary.dashboard_chart_link = ApiResult(
            "vahele jäetud",
            "Chartide sidumist ei tehtud, sest loodud chartide ID-sid ei olnud.",
        )
        return

    failed_links: list[str] = []
    for chart_id in chart_ids:
        try:
            client.put_json(f"/api/v1/chart/{chart_id}", {"dashboards": [summary.dashboard.object_id]})
        except Exception as exc:  # noqa: BLE001
            failed_links.append(f"chart ID {chart_id}: {client.sanitize(exc)}")

    if failed_links:
        summary.dashboard_chart_link = ApiResult(
            "ebaõnnestus",
            "Kõigi chartide sidumine dashboardiga ei õnnestunud: " + "; ".join(failed_links),
            summary.dashboard.object_id,
        )
    else:
        summary.dashboard_chart_link = ApiResult(
            "ok",
            "Chartide sidumine dashboardiga õnnestus API kaudu.",
            summary.dashboard.object_id,
        )


def optional_team_users() -> dict[str, dict[str, str]]:
    users: dict[str, dict[str, str]] = {}
    for prefix, default_username in (("TUULI", "tuuli"), ("KULLI", "kulli")):
        email = os.environ.get(f"SUPERSET_{prefix}_EMAIL", "")
        password = os.environ.get(f"SUPERSET_{prefix}_PASSWORD", "")
        if not email or not password:
            continue
        users[default_username] = {
            "username": os.environ.get(f"SUPERSET_{prefix}_USERNAME", default_username),
            "email": email,
            "password": password,
        }
    return users


def ensure_users(client: SupersetClient, summary: RunSummary) -> None:
    users_to_create = optional_team_users()
    if not users_to_create:
        detail = (
            "Tuuli/Külli kasutajaid ei loodud, sest .env.superset failis puuduvad "
            "paroolid/e-mailid."
        )
        summary.users["tuuli"] = ApiResult("vahele jäetud", detail)
        summary.users["kulli"] = ApiResult("vahele jäetud", detail)
        return

    try:
        existing_users = client.list_objects("/api/v1/security/users/")
        roles = client.list_objects("/api/v1/security/roles/")
        alpha_role = find_by_name(roles, "name", value="Alpha")
        alpha_role_id = int(alpha_role["id"]) if alpha_role else None
    except Exception as exc:  # noqa: BLE001
        for username in users_to_create:
            summary.users[username] = ApiResult(
                "ebaõnnestus",
                "Kasutajate API ei olnud kasutatav: " + client.sanitize(exc),
            )
        return

    for key, user in users_to_create.items():
        existing = find_by_name(existing_users, "username", value=user["username"])
        if existing:
            summary.users[key] = ApiResult("olemas", "Kasutaja oli juba olemas.", int(existing["id"]))
            continue
        payload: dict[str, Any] = {
            "username": user["username"],
            "first_name": user["username"].capitalize(),
            "last_name": "MREV",
            "email": user["email"],
            "active": True,
            "password": user["password"],
        }
        if alpha_role_id is not None:
            payload["roles"] = [alpha_role_id]
        try:
            created = client.post_json("/api/v1/security/users/", payload)
            summary.users[key] = ApiResult("loodud", "Kasutaja loodi Superseti API kaudu.", object_id(created))
        except Exception as exc:  # noqa: BLE001
            summary.users[key] = ApiResult(
                "ebaõnnestus",
                "Kasutaja loomine API kaudu ebaõnnestus: " + client.sanitize(exc),
            )


def result_line(name: str, result: ApiResult | None) -> str:
    if result is None:
        return f"- {name}: ei käivitatud"
    suffix = f" (ID {result.object_id})" if result.object_id is not None else ""
    return f"- {name}: {result.status}{suffix}. {result.detail}"


def manual_dataset_steps() -> str:
    lines = [
        "Data -> Datasets -> + Dataset",
        f"Database: {DEFAULT_DATABASE_NAME}",
        "Schema: mart",
    ]
    lines.extend(f"Table/View: {table_name}" for table_name in DATASETS)
    return "\n".join(lines)


def manual_chart_steps() -> str:
    return "\n".join(
        [
            "1. Charts -> + Chart -> Dataset `mart.v_dashboard_kpi` -> Big Number; metric `mta_ettevotteid`.",
            "2. Charts -> + Chart -> Dataset `mart.v_dashboard_kpi` -> Big Number; metric `maksuvolg_summa`.",
            "3. Charts -> + Chart -> Dataset `mart.v_dashboard_kpi` -> Big Number; metric `juhatus_muutunud_ettevotteid`.",
            "4. Charts -> + Chart -> Dataset `mart.v_maksuvolg_vanusegruppide_kaupa` -> Bar Chart; dimension `volg_vanuse_grupp`, metric `maksuvolg_summa`.",
            "5. Charts -> + Chart -> Dataset `mart.v_top_maksuvolglased` -> Table; sort `maksuvolg DESC`.",
            f"6. Dashboards -> + Dashboard -> `{DASHBOARD_TITLE}` ja lisa loodud chartid.",
        ]
    )


def write_report(summary: RunSummary, database_name: str) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    report_path = REPORT_DIR / f"superset_mrev_seadistuse_raport_{summary.started_at:%Y-%m-%d}.md"
    chart_failures = [name for name, result in summary.charts.items() if result.status == "ebaõnnestus"]
    dataset_failures = [name for name, result in summary.datasets.items() if result.status == "ebaõnnestus"]

    lines = [
        "# Superseti MREV seadistuse raport",
        "",
        f"Töö tehtud: {summary.started_at:%Y-%m-%d %H:%M:%S}",
        "",
        "## Kontrollid ja API",
        "",
        result_line(f"Superset vastas aadressil `{summary.superset_url}`", summary.superset_health),
        result_line("Login API", summary.login),
        result_line("CSRF token", summary.csrf),
        result_line("Database connection", summary.database),
        result_line("Connection test API", summary.connection_test),
        "",
        "## Database connection",
        "",
        f"- Nimi: `{database_name}`",
        "- SQLAlchemy URI kasutab `superset_readonly` kasutajat ja andmebaasi `andmeprojekt`.",
        "- URI ja parooli ei kuvata raportis ega logis.",
        "",
        "## Datasetid",
        "",
    ]
    lines.extend(result_line(f"`mart.{name}`", result) for name, result in summary.datasets.items())
    lines.append("")
    lines.append("## Dataset refresh")
    lines.append("")
    lines.extend(result_line(f"`mart.{name}`", result) for name, result in summary.dataset_refresh.items())
    lines.append("")
    lines.append("## Dashboard ja chartid")
    lines.append("")
    lines.append(result_line("Dashboard", summary.dashboard))
    lines.append(result_line("Dashboardi chartide sidumine", summary.dashboard_chart_link))
    lines.extend(result_line(name, result) for name, result in summary.charts.items())
    lines.append("")
    lines.append("## Kasutajad")
    lines.append("")
    lines.extend(result_line(name, result) for name, result in summary.users.items())
    lines.append("")
    lines.append("## Andmete muutmise kinnitus")
    lines.append("")
    lines.append("- Skript kasutas ainult Superseti REST API-t Superseti metadata objektide loomiseks.")
    lines.append("- PostgreSQL `raw`, `stage` ja `mart` andmeid ei muudetud.")
    lines.append("- `.env.superset` faili ega paroole GitHubi ei lisatud.")
    lines.append("")
    lines.append("## Käsitsi sammud vajadusel")
    lines.append("")
    if dataset_failures:
        lines.append("Datasetite käsitsi loomise juhend:")
        lines.append("")
        lines.append("```text")
        lines.append(manual_dataset_steps())
        lines.append("```")
        lines.append("")
    if chart_failures or not summary.charts or (
        summary.dashboard_chart_link and summary.dashboard_chart_link.status == "ebaõnnestus"
    ):
        lines.append("Chartide ja dashboardi käsitsi loomise juhend:")
        lines.append("")
        lines.append(manual_chart_steps())
        lines.append("")
    if not dataset_failures and not chart_failures and summary.charts:
        lines.append("- Täiendavaid käsitsi samme ei ole vaja, kui dashboard kuvab chartid ootuspäraselt.")
        lines.append("")
    lines.append("## Järgmised sammud")
    lines.append("")
    lines.append("- Logi Supersetisse kasutajaga `andrus_admin` ja kontrolli `Data -> Datasets` vaadet.")
    lines.append(f"- Ava dashboard `{DASHBOARD_TITLE}` ja kontrolli chartide paigutust.")
    lines.append("- Kui mõni chart vajab visuaalset häälestust, tee see Superseti UI-s.")

    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report_path


def main() -> int:
    started_at = datetime.now()
    try:
        load_dotenv(ENV_FILE)
        env = require_env()
        superset_url = os.environ.get("SUPERSET_URL", DEFAULT_SUPERSET_URL)
        database_name = os.environ.get("SUPERSET_DATABASE_NAME", DEFAULT_DATABASE_NAME)
        summary = RunSummary(started_at=started_at, superset_url=superset_url)
        client = SupersetClient(
            superset_url,
            [
                env["SUPERSET_ADMIN_PASSWORD"],
                env["SUPERSET_READONLY_DB_PASSWORD"],
                os.environ.get("SUPERSET_TUULI_PASSWORD", ""),
                os.environ.get("SUPERSET_KULLI_PASSWORD", ""),
            ],
        )

        print(f"Kontrollin Superseti aadressi {superset_url}")
        response = client.session.get(superset_url, timeout=30, allow_redirects=True)
        if response.status_code >= 500:
            summary.superset_health = ApiResult("ebaõnnestus", f"HTTP {response.status_code}")
            raise SupersetConfigError(f"Superset vastas HTTP {response.status_code}")
        summary.superset_health = ApiResult("ok", f"HTTP {response.status_code}")

        print("Login Superseti API-sse.")
        client.login(env["SUPERSET_ADMIN_USERNAME"], env["SUPERSET_ADMIN_PASSWORD"])
        summary.login = ApiResult("ok", "Login API tagastas access tokeni.")

        print("Küsin CSRF tokeni.")
        client.fetch_csrf_token()
        summary.csrf = ApiResult("ok", "CSRF token saadi.")

        print("Kontrollin/loon database connectioni.")
        db_id = ensure_database(
            client,
            summary,
            database_name,
            env["SUPERSET_READONLY_DB_USER"],
            env["SUPERSET_READONLY_DB_PASSWORD"],
        )
        try_connection_test(
            client,
            summary,
            database_name,
            env["SUPERSET_READONLY_DB_USER"],
            env["SUPERSET_READONLY_DB_PASSWORD"],
        )

        print("Kontrollin/loon datasetid.")
        dataset_ids = ensure_datasets(client, summary, db_id)

        print("Püüan luua chartid ja dashboardi.")
        chart_ids = ensure_charts(client, summary, dataset_ids)
        ensure_dashboard(client, summary, chart_ids)

        print("Kontrollin valikulisi Tuuli/Külli kasutajaid.")
        ensure_users(client, summary)

        report_path = write_report(summary, database_name)
        print(f"Raport kirjutatud: {report_path}")
        print("Superseti MREV seadistus valmis.")
        return 0
    except Exception as exc:  # noqa: BLE001
        safe_message = str(exc)
        for secret_name in (
            "SUPERSET_ADMIN_PASSWORD",
            "SUPERSET_READONLY_DB_PASSWORD",
            "SUPERSET_TUULI_PASSWORD",
            "SUPERSET_KULLI_PASSWORD",
        ):
            secret = os.environ.get(secret_name)
            if secret:
                safe_message = safe_message.replace(secret, "<redacted>")
        print(f"VIGA: {safe_message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
