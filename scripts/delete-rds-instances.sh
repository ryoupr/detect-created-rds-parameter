#!/bin/bash

# RDSインスタンス削除スクリプト
# 使用法: ./delete-rds-instances.sh

set -e

# 色付きテキストの設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ログ関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# RDSインスタンス一覧を取得
get_rds_instances() {
    log_info "RDSインスタンス一覧を取得中..."
    
    # JSONファイルに保存
    aws rds describe-db-instances \
        --query 'DBInstances[*].{
            Identifier:DBInstanceIdentifier,
            Engine:Engine,
            Class:DBInstanceClass,
            Status:DBInstanceStatus,
            StorageEncrypted:StorageEncrypted,
            AvailabilityZone:AvailabilityZone,
            CreatedTime:InstanceCreateTime
        }' \
        --output json > /tmp/rds_instances.json
    
    if [ $? -ne 0 ]; then
        log_error "RDSインスタンス一覧の取得に失敗しました"
        exit 1
    fi
    
    # インスタンス数をチェック
    local instance_count=$(jq length /tmp/rds_instances.json)
    if [ "$instance_count" -eq 0 ]; then
        log_warning "RDSインスタンスが見つかりませんでした"
        exit 0
    fi
    
    log_success "${instance_count}個のRDSインスタンスが見つかりました"
}

# インスタンス一覧を表形式で表示
display_instances() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}      RDSインスタンス一覧${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    # ヘッダー表示
    printf "%-4s %-30s %-12s %-15s %-12s %-8s %-20s\n" \
        "No." "インスタンス識別子" "エンジン" "インスタンスクラス" "ステータス" "暗号化" "作成日時"
    echo "--------------------------------------------------------------------------------------------------------"
    
    # インスタンス情報を表示
    local index=1
    while IFS= read -r instance; do
        local identifier=$(echo "$instance" | jq -r '.Identifier')
        local engine=$(echo "$instance" | jq -r '.Engine')
        local class=$(echo "$instance" | jq -r '.Class')
        local status=$(echo "$instance" | jq -r '.Status')
        local encrypted=$(echo "$instance" | jq -r '.StorageEncrypted')
        local created_time=$(echo "$instance" | jq -r '.CreatedTime' | cut -d'T' -f1)
        
        # 暗号化状態の表示を日本語化
        local encrypted_jp="無効"
        if [ "$encrypted" = "true" ]; then
            encrypted_jp="有効"
        fi
        
        # ステータスに応じて色付け
        local status_colored="$status"
        case "$status" in
            "available")
                status_colored="${GREEN}$status${NC}"
                ;;
            "stopped")
                status_colored="${YELLOW}$status${NC}"
                ;;
            "deleting"|"failed")
                status_colored="${RED}$status${NC}"
                ;;
        esac
        
        printf "%-4s %-30s %-12s %-15s %-20s %-8s %-20s\n" \
            "$index" "$identifier" "$engine" "$class" "$status_colored" "$encrypted_jp" "$created_time"
        
        ((index++))
    done < <(jq -c '.[]' /tmp/rds_instances.json)
    
    echo
}

# ユーザーから削除するインスタンス番号を取得
get_user_selection() {
    local total_instances=$(jq length /tmp/rds_instances.json)
    
    echo -e "${YELLOW}削除するRDSインスタンスの番号を指定してください${NC}"
    echo "- 複数の場合はカンマ区切りで指定（例: 1,3,5）"
    echo "- 範囲指定も可能（例: 1-3,5）"
    echo "- 'q' または 'quit' で終了"
    echo
    read -p "削除するインスタンス番号: " selection
    
    # 終了チェック
    if [[ "$selection" =~ ^[qQ](uit)?$ ]]; then
        log_info "処理を中止しました"
        exit 0
    fi
    
    # 空入力チェック
    if [ -z "$selection" ]; then
        log_error "番号が指定されていません"
        return 1
    fi
    
    # 選択番号の解析と検証
    selected_numbers=()
    IFS=',' read -ra ADDR <<< "$selection"
    
    for range in "${ADDR[@]}"; do
        if [[ "$range" =~ ^[0-9]+$ ]]; then
            # 単一番号
            if [ "$range" -ge 1 ] && [ "$range" -le "$total_instances" ]; then
                selected_numbers+=("$range")
            else
                log_error "無効な番号: $range (1-$total_instances の範囲で指定してください)"
                return 1
            fi
        elif [[ "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
            # 範囲指定
            local start=$(echo "$range" | cut -d'-' -f1)
            local end=$(echo "$range" | cut -d'-' -f2)
            
            if [ "$start" -ge 1 ] && [ "$start" -le "$total_instances" ] && \
               [ "$end" -ge 1 ] && [ "$end" -le "$total_instances" ] && \
               [ "$start" -le "$end" ]; then
                for ((i=start; i<=end; i++)); do
                    selected_numbers+=("$i")
                done
            else
                log_error "無効な範囲: $range"
                return 1
            fi
        else
            log_error "無効な形式: $range"
            return 1
        fi
    done
    
    # 重複削除
    selected_numbers=($(printf '%s\n' "${selected_numbers[@]}" | sort -nu))
    
    if [ ${#selected_numbers[@]} -eq 0 ]; then
        log_error "有効な番号が指定されていません"
        return 1
    fi
    
    return 0
}

# 選択されたインスタンスの詳細を表示
show_selected_instances() {
    echo
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}     削除予定のインスタンス${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo
    
    selected_instances=()
    
    for num in "${selected_numbers[@]}"; do
        local instance=$(jq -r ".[$((num-1))]" /tmp/rds_instances.json)
        local identifier=$(echo "$instance" | jq -r '.Identifier')
        local engine=$(echo "$instance" | jq -r '.Engine')
        local status=$(echo "$instance" | jq -r '.Status')
        
        echo "[$num] $identifier ($engine, $status)"
        selected_instances+=("$identifier")
    done
    
    echo
}

# 最終確認
confirm_deletion() {
    local count=${#selected_instances[@]}
    
    echo -e "${RED}警告: 以下の${count}個のRDSインスタンスを削除します${NC}"
    echo -e "${RED}この操作は取り消すことができません！${NC}"
    echo
    
    read -p "本当に削除しますか？ (yes/no): " confirmation
    
    case "$confirmation" in
        [yY][eE][sS])
            return 0
            ;;
        *)
            log_info "削除処理をキャンセルしました"
            exit 0
            ;;
    esac
}

# スナップショット作成オプション
ask_snapshot_option() {
    echo
    read -p "削除前に最終スナップショットを作成しますか？ (y/n): " create_snapshot
    
    case "$create_snapshot" in
        [yY])
            create_final_snapshot=true
            ;;
        *)
            create_final_snapshot=false
            ;;
    esac
}

# RDSインスタンス削除
delete_instances() {
    local total=${#selected_instances[@]}
    local success_count=0
    local failed_instances=()
    
    echo
    log_info "RDSインスタンスの削除を開始します..."
    echo
    
    for identifier in "${selected_instances[@]}"; do
        log_info "インスタンス '$identifier' を削除中..."
        
        local delete_cmd="aws rds delete-db-instance --db-instance-identifier $identifier"
        
        if [ "$create_final_snapshot" = true ]; then
            local snapshot_id="${identifier}-final-snapshot-$(date +%Y%m%d-%H%M%S)"
            delete_cmd="$delete_cmd --final-db-snapshot-identifier $snapshot_id"
            log_info "最終スナップショット作成: $snapshot_id"
        else
            delete_cmd="$delete_cmd --skip-final-snapshot"
        fi
        
        if eval "$delete_cmd" >/dev/null 2>&1; then
            log_success "インスタンス '$identifier' の削除を開始しました"
            ((success_count++))
        else
            log_error "インスタンス '$identifier' の削除に失敗しました"
            failed_instances+=("$identifier")
        fi
        
        # 少し待機
        sleep 2
    done
    
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}        削除処理結果${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    log_success "削除開始: $success_count/$total インスタンス"
    
    if [ ${#failed_instances[@]} -gt 0 ]; then
        log_error "削除失敗したインスタンス:"
        for failed in "${failed_instances[@]}"; do
            echo "  - $failed"
        done
    fi
    
    if [ "$success_count" -gt 0 ]; then
        echo
        log_info "削除状況を確認するには以下のコマンドを実行してください:"
        echo "aws rds describe-db-instances --query 'DBInstances[?DBInstanceStatus==\`deleting\`].{Identifier:DBInstanceIdentifier,Status:DBInstanceStatus}' --output table"
    fi
}

# メイン処理
main() {
    echo -e "${BLUE}RDSインスタンス削除ツール${NC}"
    echo -e "${BLUE}========================${NC}"
    echo
    
    # 前提条件チェック
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLIがインストールされていません"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jqがインストールされていません"
        exit 1
    fi
    
    # AWS認証チェック
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS認証が設定されていません"
        exit 1
    fi
    
    # RDSインスタンス一覧取得
    get_rds_instances
    
    # インスタンス一覧表示
    display_instances
    
    # ユーザー選択取得（失敗時は再試行）
    while ! get_user_selection; do
        echo "再度入力してください"
        echo
    done
    
    # 選択されたインスタンス表示
    show_selected_instances
    
    # スナップショットオプション
    ask_snapshot_option
    
    # 最終確認
    confirm_deletion
    
    # 削除実行
    delete_instances
    
    # 一時ファイル削除
    rm -f /tmp/rds_instances.json
    
    echo
    log_success "処理が完了しました"
}

# スクリプト実行
main "$@"
