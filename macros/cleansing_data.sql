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
{# unit_test を実行する際に参照されるUnitTestNode は meta を持たないが、#}
{# 元のモデルのIDであるtested_node_unique_idを保持しているため、graph.nodes を逆引きする #}
{%- set meta = model.get('meta') or model.get('config', {}).get('meta') or config.get('meta', {}) or {} -%}
{%- if (not meta or not meta.get('source_delivery_type')) and model.get('resource_type') == 'unit_test' and graph and graph.nodes -%}
    {%- set tested_node = graph.nodes.get(model.get('tested_node_unique_id')) -%}
    {%- if tested_node -%}
        {%- set meta = tested_node.get('config', {}).get('meta') or tested_node.get('meta', {}) or {} -%}
    {%- endif -%}
{%- endif -%}

{# 2.ローカル変数群の整備 #}
{%- set delivery_type = meta.get('source_delivery_type') or meta.get('strategy') or meta.get('macro_name') -%}
{%- set pk_col = meta.get('pk_col') -%}
{%- set updated_at = meta.get('updated_at') -%}
{%- set created_at = meta.get('created_at') -%}
{%- set loaded_at = meta.get('loaded_at') -%}
{%- set expiration_day = meta.get('expiration_day') -%}

{# 3. 指定された個別マクロを呼び出し #}
{%- if delivery_type in ['master_diff', 'cleansing_master_diff_data'] -%}
    {{ cleansing_master_diff_data(
        input=input,
        output=output,
        pk_col=pk_col,
        updated_at=updated_at,
        created_at=created_at,
        loaded_at=loaded_at,
        expiration_day=expiration_day,
        **kwargs
    ) }}
{%- elif delivery_type in ['master_all', 'cleansing_master_all_data'] -%}
    {{ cleansing_master_all_data(
        input=input,
        output=output,
        pk_col=pk_col,
        updated_at=updated_at,
        created_at=created_at,
        loaded_at=loaded_at,
        expiration_day=expiration_day,
        **kwargs
    ) }}
{%- elif delivery_type in ['transaction_diff', 'cleansing_transaction_diff_data'] -%}
    {{ cleansing_transaction_diff_data(
        input=input,
        output=output,
        pk_col=pk_col,
        updated_at=updated_at,
        created_at=created_at,
        loaded_at=loaded_at,
        expiration_day=expiration_day,
        **kwargs
    ) }}
{%- else -%}
    {{ exceptions.raise_compiler_error(
        "Model '" ~ model.name ~ "' requires valid 'meta.source_delivery_type' (one of: master_diff, master_all, transaction_diff)"
    ) }}
{%- endif -%}

{%- endmacro -%}
