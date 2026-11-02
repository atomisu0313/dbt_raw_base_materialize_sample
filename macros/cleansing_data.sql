{%- macro cleansing_data(input, output) -%}

{# 0. 基準日 execution_date の必須チェック（事故防止のため明示指定を強制） #}
{%- set raw_execution_date = var("execution_date", none) -%}
{%- if not raw_execution_date -%}
    {{ exceptions.raise_compiler_error(
        "Variable 'execution_date' is required for model '" ~ model.name ~ "'. " ~
        "Please specify it explicitly, e.g.: dbt run --vars '{\"execution_date\": \"YYYY-MM-DD\"}'"
    ) }}
{%- endif -%}

{# 1. モデルの meta から source_delivery_type / macro_name を取得 #}
{%- set meta = model.get('meta') or model.get('config', {}).get('meta') or config.get('meta', {}) or {} -%}
{%- set delivery_type = meta.get('source_delivery_type') or meta.get('strategy') or meta.get('macro_name') -%}

{# 2. 指定された個別マクロを呼び出し（config 設定や個別ロジックは各マクロに委譲） #}
{%- if delivery_type in ['master_diff', 'cleansing_master_diff_data'] -%}
    {{ cleansing_master_diff_data(input=input, output=output, **kwargs) }}
{%- elif delivery_type in ['master_all', 'cleansing_master_all_data'] -%}
    {{ cleansing_master_all_data(input=input, output=output, **kwargs) }}
{%- elif delivery_type in ['transaction_diff', 'cleansing_transaction_diff_data'] -%}
    {{ cleansing_transaction_diff_data(input=input, output=output, **kwargs) }}
{%- else -%}
    {{ exceptions.raise_compiler_error(
        "Model '" ~ model.name ~ "' requires valid 'meta.source_delivery_type' (one of: master_diff, master_all, transaction_diff)"
    ) }}
{%- endif -%}

{%- endmacro -%}
