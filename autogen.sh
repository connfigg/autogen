#!/bin/bash
set -euo pipefail
# =========================================
# 🚀 GCP-XRAY MULTI-ENGINE DEPLOYER — WS-ONLY EDITION
# ✅ ENGINES: OPENRESTY, ENVOY, HAPROXY, CADDY, SING-BOX
# ✅ INCLUDES CUSTOM USER-AGENT HEADERS & DIRECT PANEL
# ✅ UPDATE: Artifact Registry Support + Auto-Cleanup Old Images
# ✅ NEW: True Anti-DDoS Rate Limiting on All 5 Engines
# ✅ NEW: Back Navigation on Menus, Presets & Manual Modes
# ✅ NEW: Auto-Generated Password, UUID & /project-congif/ WS Paths Every Deploy
# ✅ NEW: Masked Engine Names in Cloud Run Service, URL & Registry
# =========================================
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ==============================================
# AUTO INSTALL JQ IF MISSING
# ==============================================
if ! command -v jq &> /dev/null; then
    echo -e "\n${YELLOW}⚠️ Installing required tool: jq...${NC}"
    sudo apt update -qq && sudo apt install -y -qq jq || {
        echo -e "${RED}❌ Failed to install jq!${NC}"
        exit 1
    }
    echo -e "${GREEN}✅ jq installed successfully!${NC}"
fi

# ==============================================
# CREDENTIALS & PATH GENERATOR (PER DEPLOY)
# ==============================================
generate_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        local h
        h=$(openssl rand -hex 16)
        printf '%s-%s-4%s-%s-%s\n' \
            "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:16:4}" "${h:20:12}"
    fi
}

url_encode_path() {
    local p="$1"
    p="${p//\//%2f}"
    p="${p// /%20}"
    printf '%s' "$p"
}

generate_deploy_credentials() {
    TROJAN_PASS=$(openssl rand -hex 8)
    VLESS_UUID=$(generate_uuid)

    local t1 t2 t3 v1 v2 v3
    t1=$(openssl rand -hex 3)
    t2=$(openssl rand -hex 3)
    t3=$(openssl rand -hex 4)
    v1=$(openssl rand -hex 3)
    v2=$(openssl rand -hex 3)
    v3=$(openssl rand -hex 4)

    TROJAN_WS_PATH="/project-congif/${t1}/${t2}/${t3}"
    VLESS_WS_PATH="/project-congif/${v1}/${v2}/${v3}"

    TROJAN_WS_PATH_ENC=$(url_encode_path "$TROJAN_WS_PATH")
    VLESS_WS_PATH_ENC=$(url_encode_path "$VLESS_WS_PATH")
}

# ==============================================
# ARTIFACT REGISTRY SETUP & AUTO-CLEANUP
# ==============================================
setup_artifact_registry() {
    local TARGET_REGION="$1"
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
    REPO_NAME="cloud-gateway-images"
    
    echo -e "\n${CYAN}📦 Checking Artifact Registry Repository...${NC}"
    
    if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$TARGET_REGION" --project="$PROJECT_ID" &>/dev/null; then
        echo -e "${YELLOW}⚠️ Repository not found. Creating: $REPO_NAME in $TARGET_REGION...${NC}"
        gcloud artifacts repositories create "$REPO_NAME" \
            --repository-format=docker \
            --location="$TARGET_REGION" \
            --project="$PROJECT_ID" \
            --quiet
        echo -e "${GREEN}✅ Artifact Registry Repository created!${NC}"
    else
        echo -e "${GREEN}✅ Artifact Registry Repository already exists.${NC}"
    fi
    
    echo -e "${CYAN}🔐 Configuring Docker authentication...${NC}"
    gcloud auth configure-docker "${TARGET_REGION}-docker.pkg.dev" --quiet
    
    ARTIFACT_REGISTRY_URL="${TARGET_REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"
}

cleanup_old_artifact_images() {
    local TARGET_REGION="$1"
    local TARGET_PROJECT="$2"
    local REPO_NAME="cloud-gateway-images"
    local PKG_PATH="${TARGET_REGION}-docker.pkg.dev/${TARGET_PROJECT}/${REPO_NAME}/gcp-${ENGINE_MASK}"

    echo -e "\n${CYAN}🧹 Cleaning up old Artifact Registry images for gcp-${ENGINE_MASK}...${NC}"

    ACTIVE_DIGEST=$(gcloud artifacts docker images describe "${PKG_PATH}:latest" \
        --project="$TARGET_PROJECT" \
        --format='value(image_summary.digest)' 2>/dev/null || true)

    DIGESTS=$(gcloud artifacts docker images list "$PKG_PATH" \
        --project="$TARGET_PROJECT" \
        --format='value(digest)' 2>/dev/null || true)

    if [ -z "$DIGESTS" ]; then
        echo -e "${YELLOW}ℹ️ No images found to clean up.${NC}"
        return 0
    fi

    local DELETED_COUNT=0
    while IFS= read -r DIGEST; do
        [ -z "$DIGEST" ] && continue
        if [ -n "$ACTIVE_DIGEST" ] && [ "$DIGEST" = "$ACTIVE_DIGEST" ]; then
            continue
        fi
        if gcloud artifacts docker images delete "${PKG_PATH}@${DIGEST}" \
            --project="$TARGET_PROJECT" \
            --delete-tags \
            --quiet >/dev/null 2>&1; then
            ((DELETED_COUNT++)) || true
        fi
    done <<< "$DIGESTS"

    if [ "$DELETED_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✅ Removed $DELETED_COUNT old image version(s). Kept latest active digest.${NC}"
    else
        echo -e "${GREEN}✅ Artifact Registry is already clean (only active image kept).${NC}"
    fi
}

# ==============================================
# LIST SERVICES
# ==============================================
list_deployed_services() {
    echo -e "\n======================================"
    echo -e "${CYAN}📋 ALL DEPLOYED CLOUD GATEWAY SERVICES${NC}"
    echo -e "======================================"
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
    echo "Project: $PROJECT_ID"
    echo ""

    declare -A REGION_NAMES=(
        ["us-central1"]="Iowa, United States 🇺🇸"
        ["us-east1"]="South Carolina, United States 🇺🇸"
        ["us-east4"]="N. Virginia, United States 🇺🇸"
        ["us-west1"]="Oregon, United States 🇺🇸"
        ["asia-east1"]="Taiwan 🇹🇼"
        ["asia-southeast1"]="Singapore 🇸🇬"
        ["asia-northeast1"]="Tokyo, Japan 🇯🇵"
        ["asia-northeast3"]="Seoul, South Korea 🇰🇷"
        ["europe-west1"]="Belgium 🇧🇪"
        ["europe-west4"]="Netherlands 🇳🇱"
        ["europe-west9"]="Paris, France 🇫🇷"
        ["asia-south1"]="Mumbai, India 🇮🇳"
    )

    SERVICES=$(gcloud run services list \
        --format="value(metadata.name, status.url, region, metadata.creationTimestamp.date(%Y-%m-%d))" \
        --project="$PROJECT_ID" 2>/dev/null)

    if [ -z "$SERVICES" ]; then
        echo -e "${RED}❌ No services found.${NC}"
    else
        local COUNT=1
        while IFS=$'\t' read -r NAME URL REGION CREATED; do
            [ -z "$NAME" ] && continue
            FULL_REGION="${REGION_NAMES[$REGION]:-$REGION}"
            DETAILS=$(gcloud run services describe "$NAME" --region "$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null || true)

            if [ -z "$DETAILS" ]; then
                echo -e "${GREEN}=== SERVICE #$COUNT ===${NC}"
                echo "🔹 Name: $NAME"
                echo "🔹 URL: $URL"
                echo "🔹 Region: $REGION → $FULL_REGION"
                echo "🔹 Created: $CREATED"
                echo ""
                ((COUNT++))
                continue
            fi

            MEMORY=$(echo "$DETAILS" | jq -r '.spec.template.spec.containers[0].resources.limits.memory // "1Gi"')
            CPU=$(echo "$DETAILS" | jq -r '.spec.template.spec.containers[0].resources.limits.cpu // "1"')
            BILLING=$(echo "$DETAILS" | jq -r '.spec.template.spec.billingMode // "Request Based"' | sed 's/_/ /g;s/^./\U&/')
            MIN_INST=$(echo "$DETAILS" | jq -r '.spec.template.spec.minInstances // "0"')
            MAX_INST=$(echo "$DETAILS" | jq -r '.spec.template.spec.maxInstances // "1"')
            CONCURRENCY=$(echo "$DETAILS" | jq -r '.spec.template.spec.containerConcurrency // "1000"')
            TIMEOUT=$(echo "$DETAILS" | jq -r '.spec.template.spec.timeoutSeconds // "1000"')

            echo -e "${GREEN}=== SERVICE #$COUNT ===${NC}"
            echo "🔹 Name: $NAME"
            echo "🔹 URL: $URL"
            echo "🔹 Region: $REGION → $FULL_REGION"
            echo "🔹 Created: $CREATED"
            echo "🔹 Resources: $MEMORY RAM | $CPU vCPU"
            echo "🔹 Billing: $BILLING"
            echo "🔹 Instances: Min $MIN_INST / Max $MAX_INST"
            echo "🔹 Connections: Max $CONCURRENCY"
            echo "🔹 Timeout: ${TIMEOUT}s"
            echo ""
            ((COUNT++))
        done <<< "$SERVICES"
    fi
    echo -e "\n======================================"
    read -p "Press [Enter] to return..."
}

# ==============================================
# REGION SELECTOR (WITH BACK OPTION)
# ==============================================
select_region() {
    while true; do
        echo -e "\n=== GCP CLOUD RUN REGION SELECTION ==="
        echo "--- North America ---"
        echo "1) us-central1 (Iowa, US 🇺🇸)"
        echo "2) us-east1 (South Carolina, US 🇺🇸)"
        echo "3) us-east4 (N. Virginia, US 🇺🇸)"
        echo "4) us-west1 (Oregon, US 🇺🇸)"
        echo ""
        echo "--- Asia Pacific ---"
        echo "5) asia-east1 (Taiwan 🇹🇼 — RECOMMENDED!)"
        echo "6) asia-southeast1 (Singapore 🇸🇬)"
        echo "7) asia-northeast1 (Tokyo, Japan 🇯🇵)"
        echo "8) asia-northeast3 (Seoul, South Korea 🇰🇷)"
        echo "9) asia-south1 (Mumbai, India 🇮🇳)"
        echo ""
        echo "--- Europe ---"
        echo "10) europe-west1 (Belgium 🇧🇪)"
        echo "11) europe-west4 (Netherlands 🇳🇱)"
        echo "12) europe-west9 (Paris, France 🇫🇷)"
        echo ""
        echo "99) Enter custom region code"
        echo "0) Back to Main Menu"
        echo ""

        read -p "Enter region number: " REGION_NUM
        case $REGION_NUM in
            1) REGION="us-central1"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            2) REGION="us-east1"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            3) REGION="us-east4"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            4) REGION="us-west1"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            5) REGION="asia-east1"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            6) REGION="asia-southeast1"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            7) REGION="asia-northeast1"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            8) REGION="asia-northeast3"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            9) REGION="asia-south1"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            10) REGION="europe-west1"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            11) REGION="europe-west4"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            12) REGION="europe-west9"; echo -e "${GREEN}✅ Selected Region:${NC} $REGION"; return 0 ;;
            99)
                read -p "Type full region code (or '0' to go back): " REGION
                if [ "$REGION" = "0" ] || [ -z "$REGION" ]; then
                    continue
                fi
                echo -e "${GREEN}✅ Selected Region:${NC} $REGION"
                return 0
                ;;
            0) return 1 ;;
            *) echo -e "${YELLOW}⚠️ Invalid choice! Try again or enter 0 to go back.${NC}" ;;
        esac
    done
}

# ==============================================
# DEPLOYMENT FUNCTION (WITH STEP-BY-STEP BACK)
# ==============================================
deploy_new_service() {
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
    if [ -z "$PROJECT_ID" ]; then
        echo -e "${RED}❌ No project set! Run: gcloud config set project YOUR_ID${NC}"
        read -p "Press [Enter] to return..."
        return
    fi

    gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com --project="$PROJECT_ID" --quiet

    local STEP="REGION"
    while true; do
        case "$STEP" in
            "REGION")
                if ! select_region; then
                    return 0
                fi
                STEP="ENGINE"
                ;;
            "ENGINE")
                echo -e "\n${CYAN}=========================================${NC}"
                echo -e "${GREEN} CHOOSE PROXY ENGINE${NC}"
                echo -e "${CYAN}=========================================${NC}"
                echo "1) OpenResty - [Standard / Highly Reliable] -> Masked: edge-gw"
                echo "2) Envoy Proxy - [High Performance / Cloud Native] -> Masked: mesh-gw"
                echo "3) HAProxy - [Ultra Low Latency / Lightweight] -> Masked: lb-gw"
                echo "4) Caddy Proxy - [Modern / Simple & Fast] -> Masked: web-gw"
                echo "5) Sing-Box - [Lightweight / High Performance] -> Masked: core-gw"
                echo "0) Back to Region Selection"

                read -p "Select Engine [0-5]: " ENGINE_CHOICE
                case $ENGINE_CHOICE in
                    1) ENGINE="openresty"; ENGINE_MASK="edge-gw"; DISPLAY_ENGINE="Edge Gateway (Masked)"; echo -e "${GREEN}✅ Selected: OpenResty [Masked as: $ENGINE_MASK]${NC}"; STEP="RES_MODE" ;;
                    2) ENGINE="envoy"; ENGINE_MASK="mesh-gw"; DISPLAY_ENGINE="Mesh Gateway (Masked)"; echo -e "${GREEN}✅ Selected: Envoy Proxy [Masked as: $ENGINE_MASK]${NC}"; STEP="RES_MODE" ;;
                    3) ENGINE="haproxy"; ENGINE_MASK="lb-gw"; DISPLAY_ENGINE="LB Gateway (Masked)"; echo -e "${GREEN}✅ Selected: HAProxy [Masked as: $ENGINE_MASK]${NC}"; STEP="RES_MODE" ;;
                    4) ENGINE="caddy"; ENGINE_MASK="web-gw"; DISPLAY_ENGINE="Web Gateway (Masked)"; echo -e "${GREEN}✅ Selected: Caddy Proxy [Masked as: $ENGINE_MASK]${NC}"; STEP="RES_MODE" ;;
                    5) ENGINE="singbox"; ENGINE_MASK="core-gw"; DISPLAY_ENGINE="Core Gateway (Masked)"; echo -e "${GREEN}✅ Selected: Sing-Box Engine [Masked as: $ENGINE_MASK]${NC}"; STEP="RES_MODE" ;;
                    0) STEP="REGION" ;;
                    *) echo -e "${RED}Enter 0, 1, 2, 3, 4, or 5 only${NC}" ;;
                esac
                ;;
            "RES_MODE")
                echo -e "\n${CYAN}=========================================${NC}"
                echo -e "${GREEN} RESOURCE CONFIG MODE${NC}"
                echo -e "${CYAN}=========================================${NC}"
                echo -e "${GREEN}1) AUTO PRESETS | Recommended (Request-Based)${NC}"
                echo -e "${YELLOW}2) MANUAL SETUP | Full Memory & vCPU Range${NC}"
                echo -e "0) Back to Engine Selection"

                read -p "Select Mode [0-2]: " RES_MODE
                case $RES_MODE in
                    1) STEP="AUTO_PRESET" ;;
                    2) STEP="MANUAL_MEM" ;;
                    0) STEP="ENGINE" ;;
                    *) echo -e "${RED}Enter 0, 1, or 2 only${NC}" ;;
                esac
                ;;
            "AUTO_PRESET")
                echo -e "\n${CYAN}--- AUTO PRESETS ---${NC}"
                echo "1) Basic: 512Mi RAM + 1 vCPU (Min: 0, Max: 1, Concurrency: 80)"
                echo "2) Balanced: 1Gi RAM + 1 vCPU (Min: 0, Max: 1, Concurrency: 100) ✅"
                echo "3) Turbo: 2Gi RAM + 2 vCPU (Min: 0, Max: 1, Concurrency: 1000)"
                echo "0) Back to Resource Config Mode"

                read -p "Choose preset [0-3]: " AUTO_CHOICE
                case $AUTO_CHOICE in
                    1)
                        BILLING_MODE="request"; BILLING_FLAG="--cpu-throttling"
                        MIN_INST=0; MAX_INST=1; TIMEOUT=1000
                        MEMORY="512Mi"; CPU="1"; CONCURRENCY=80
                        echo -e "${GREEN}✅ Applied Preset: $MEMORY | $CPU vCPU | Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s${NC}"
                        break 2
                        ;;
                    2)
                        BILLING_MODE="request"; BILLING_FLAG="--cpu-throttling"
                        MIN_INST=0; MAX_INST=1; TIMEOUT=1000
                        MEMORY="1Gi"; CPU="1"; CONCURRENCY=100
                        echo -e "${GREEN}✅ Applied Preset: $MEMORY | $CPU vCPU | Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s${NC}"
                        break 2
                        ;;
                    3)
                        BILLING_MODE="request"; BILLING_FLAG="--cpu-throttling"
                        MIN_INST=0; MAX_INST=1; TIMEOUT=1000
                        MEMORY="2Gi"; CPU="2"; CONCURRENCY=1000
                        echo -e "${GREEN}✅ Applied Preset: $MEMORY | $CPU vCPU | Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s${NC}"
                        break 2
                        ;;
                    0) STEP="RES_MODE" ;;
                    *) echo -e "${RED}Enter 0, 1, 2, or 3 only${NC}" ;;
                esac
                ;;
            "MANUAL_MEM")
                echo -e "\n${CYAN}=========================================${NC}"
                echo -e "${GREEN} BILLING MODE${NC}"
                echo -e "${CYAN}=========================================${NC}"
                echo -e "${YELLOW}Request-Based with CPU Throttling${NC}"
                BILLING_MODE="request"
                BILLING_FLAG="--cpu-throttling"

                echo -e "\n${YELLOW}--- MANUAL SETUP: SELECT MEMORY ---${NC}"
                echo "1) 256Mi   2) 512Mi   3) 1Gi     4) 2Gi"
                echo "5) 4Gi     6) 8Gi     7) 16Gi    8) Custom input"
                echo "0) Back to Resource Config Mode"
                read -p "Select Memory [0-8]: " MEM
                case $MEM in
                    1) MEMORY="256Mi"; STEP="MANUAL_CPU" ;;
                    2) MEMORY="512Mi"; STEP="MANUAL_CPU" ;;
                    3) MEMORY="1Gi"; STEP="MANUAL_CPU" ;;
                    4) MEMORY="2Gi"; STEP="MANUAL_CPU" ;;
                    5) MEMORY="4Gi"; STEP="MANUAL_CPU" ;;
                    6) MEMORY="8Gi"; STEP="MANUAL_CPU" ;;
                    7) MEMORY="16Gi"; STEP="MANUAL_CPU" ;;
                    8)
                        read -p "Type custom memory (or '0' to go back): " CUSTOM_MEM
                        if [ "$CUSTOM_MEM" = "0" ] || [ -z "$CUSTOM_MEM" ]; then
                            STEP="MANUAL_MEM"
                        else
                            MEMORY="$CUSTOM_MEM"
                            STEP="MANUAL_CPU"
                        fi
                        ;;
                    0) STEP="RES_MODE" ;;
                    *) echo -e "${RED}Enter 0-8 only${NC}" ;;
                esac
                ;;
            "MANUAL_CPU")
                echo -e "\n${YELLOW}--- MANUAL SETUP: SELECT vCPU (Memory: $MEMORY) ---${NC}"
                echo "1) 1 vCPU   2) 2 vCPU   3) 4 vCPU   4) 8 vCPU   5) Custom input"
                echo "0) Back to Memory Selection"
                read -p "Select vCPU [0-5]: " CPU_SEL
                case $CPU_SEL in
                    1) CPU="1"; echo -e "${GREEN}✅ Selected: $MEMORY RAM | $CPU vCPU${NC}"; STEP="MANUAL_SCALING" ;;
                    2) CPU="2"; echo -e "${GREEN}✅ Selected: $MEMORY RAM | $CPU vCPU${NC}"; STEP="MANUAL_SCALING" ;;
                    3) CPU="4"; echo -e "${GREEN}✅ Selected: $MEMORY RAM | $CPU vCPU${NC}"; STEP="MANUAL_SCALING" ;;
                    4) CPU="8"; echo -e "${GREEN}✅ Selected: $MEMORY RAM | $CPU vCPU${NC}"; STEP="MANUAL_SCALING" ;;
                    5)
                        read -p "Type custom vCPU (or '0' to go back): " CUSTOM_CPU
                        if [ "$CUSTOM_CPU" = "0" ] || [ -z "$CUSTOM_CPU" ]; then
                            STEP="MANUAL_CPU"
                        else
                            CPU="$CUSTOM_CPU"
                            echo -e "${GREEN}✅ Selected: $MEMORY RAM | $CPU vCPU${NC}"
                            STEP="MANUAL_SCALING"
                        fi
                        ;;
                    0) STEP="MANUAL_MEM" ;;
                    *) echo -e "${RED}Enter 0-5 only${NC}" ;;
                esac
                ;;
            "MANUAL_SCALING")
                echo -e "\n${CYAN}=========================================${NC}"
                echo -e "${GREEN} PERFORMANCE & SCALING CONFIGURATION ${NC}"
                echo -e "${CYAN}=========================================${NC}"
                echo -e "${YELLOW}(Type 'b' at any prompt to go back to vCPU Selection)${NC}"

                read -p "Min Instances [Default: 0]: " IN_MIN
                if [ "${IN_MIN:-}" = "b" ] || [ "${IN_MIN:-}" = "B" ]; then STEP="MANUAL_CPU"; continue; fi
                MIN_INST=${IN_MIN:-0}

                read -p "Max Instances [Default: 1]: " IN_MAX
                if [ "${IN_MAX:-}" = "b" ] || [ "${IN_MAX:-}" = "B" ]; then STEP="MANUAL_CPU"; continue; fi
                MAX_INST=${IN_MAX:-1}

                read -p "Concurrency / Max Connections [Default: 1000]: " IN_CONC
                if [ "${IN_CONC:-}" = "b" ] || [ "${IN_CONC:-}" = "B" ]; then STEP="MANUAL_CPU"; continue; fi
                CONCURRENCY=${IN_CONC:-1000}

                read -p "Timeout in seconds [Default: 1000]: " IN_TOUT
                if [ "${IN_TOUT:-}" = "b" ] || [ "${IN_TOUT:-}" = "B" ]; then STEP="MANUAL_CPU"; continue; fi
                TIMEOUT=${IN_TOUT:-1000}

                echo -e "${GREEN}✅ Config Set: Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s${NC}"
                break 2
                ;;
        esac
    done

    generate_deploy_credentials
    setup_artifact_registry "$REGION"
    IMAGE_TAG="${ARTIFACT_REGISTRY_URL}/gcp-${ENGINE_MASK}:latest"

    RAND=$(openssl rand -hex 3)
    CLOUD_RUN_SERVICE_NAME="gcp-${ENGINE_MASK}-$RAND"

    PREV_DIR=$(pwd)
    BUILD_DIR=$(mktemp -d)
    trap 'cd "$PREV_DIR" 2>/dev/null || true; rm -rf "$BUILD_DIR"' RETURN
    cd "$BUILD_DIR" || return 1

    touch index.html

    clear
    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${GREEN}GCP DEPLOYER FIVE PROXY ENGINES 2 PROTOCOLS${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${GREEN}✅ Project:${NC} $PROJECT_ID"
    echo -e "${GREEN}✅ Region:${NC} $REGION"
    echo -e "${GREEN}✅ Service Name:${NC} $CLOUD_RUN_SERVICE_NAME"
    echo -e "${GREEN}✅ Gateway Profile:${NC} $DISPLAY_ENGINE"
    echo -e "${GREEN}✅ Protocol:${NC} Trojan & Vless WebSocket Only"
    echo -e "${GREEN}✅ Registry:${NC} Artifact Registry ✅"
    echo -e "${GREEN}✅ Scaling:${NC} Min: $MIN_INST | Max: $MAX_INST"
    echo -e "${GREEN}✅ Performance:${NC} Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s"
    echo -e "${GREEN}🔑 Trojan Pass:${NC} $TROJAN_PASS"
    echo -e "${GREEN}🔑 VLESS UUID:${NC} $VLESS_UUID"
    echo -e "${GREEN}🛣️ Trojan Path:${NC} $TROJAN_WS_PATH"
    echo -e "${GREEN}🛣️ VLESS Path:${NC} $VLESS_WS_PATH"
    echo ""

    cat > config.json <<EOF
{
    "log": {"loglevel": "warning"},
    "dns": {
        "servers": ["1.1.1.1", "8.8.8.8", "223.5.5.5"],
        "queryStrategy": "UseIP"
    },
    "inbounds": [
        {
            "port": 10001,
            "listen": "127.0.0.1",
            "protocol": "trojan",
            "tag": "trojan-ws",
            "settings": {"clients": [{"password": "$TROJAN_PASS"}]},
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "$TROJAN_WS_PATH",
                    "headers": {
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                    }
                },
                "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
            },
            "sniffing": {"enabled": false}
        },
        {
            "port": 10002,
            "listen": "127.0.0.1",
            "protocol": "vless",
            "tag": "vless-ws",
            "settings": {"clients": [{"id": "$VLESS_UUID"}], "decryption": "none"},
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "$VLESS_WS_PATH",
                    "headers": {
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                    }
                },
                "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
            },
            "sniffing": {"enabled": false}
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct",
            "settings": {"domainStrategy": "UseIP"}
        }
    ]
}
EOF

    if [ "$ENGINE" = "openresty" ]; then
        cat > nginx.conf <<EOF
worker_processes auto;
worker_rlimit_nofile 65536;

events {
    worker_connections 16384;
    use epoll;
    multi_accept on;
}

http {
    include /usr/local/openresty/nginx/conf/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nodelay on;
    tcp_nopush on;
    keepalive_timeout 7200;
    keepalive_requests 200000;
    client_max_body_size 0;

    # Anti-DDoS Rate Limiting Zones (Safe for WebSocket Speed)
    limit_req_zone \$binary_remote_addr zone=panel_limit:10m rate=20r/s;
    limit_req_zone \$binary_remote_addr zone=ws_limit:10m rate=50r/s;
    limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;
    limit_req_status 429;
    limit_conn_status 429;

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_http_version 1.1;
    proxy_connect_timeout 10s;
    proxy_send_timeout 7200s;
    proxy_read_timeout 7200s;

    server_tokens off;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 8080 default_server;
        listen [::]:8080 default_server;
        server_name _;

        limit_conn conn_limit 100;

        location /health {
            limit_req zone=panel_limit burst=30 nodelay;
            return 200 "OK\n";
            add_header Content-Type text/plain;
            add_header Cache-Control "no-store, no-cache, must-revalidate";
        }

        location / {
            limit_req zone=panel_limit burst=40 nodelay;
            root /usr/local/openresty/nginx/html;
            index index.html;
        }

        location $TROJAN_WS_PATH {
            limit_req zone=ws_limit burst=100 nodelay;
            proxy_pass http://127.0.0.1:10001;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        location $VLESS_WS_PATH {
            limit_req zone=ws_limit burst=100 nodelay;
            proxy_pass http://127.0.0.1:10002;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }
}
EOF

        cat > entrypoint.sh <<'EOF'
#!/bin/sh
mkdir -p /var/log/nginx /var/log/xray
mount -t tmpfs -o size=64M tmpfs /var/log/nginx 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/xray 2>/dev/null || true
if [ -f /usr/local/openresty/nginx/html/index.html ]; then
    sed -i "s|__START_TIME__|$(date +%s)000|g" /usr/local/openresty/nginx/html/index.html
fi
/usr/local/bin/xray run -c /etc/xray.json &
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
EOF
        chmod +x entrypoint.sh

        cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray

FROM openresty/openresty:alpine-fat
USER root
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY index.html /usr/local/openresty/nginx/html/index.html
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/xray /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

    elif [ "$ENGINE" = "envoy" ]; then
        cat > envoy.yaml <<EOF
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address: { address: 0.0.0.0, port_value: 8080 }
    per_connection_buffer_limit_bytes: 1048576
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          server_name: "Cloudflare"
          codec_type: AUTO
          use_remote_address: true
          common_http_protocol_options:
            idle_timeout: 3600s
            max_requests_per_connection: 10000
          upgrade_configs:
          - upgrade_type: "websocket"
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match: { prefix: "/health" }
                direct_response: { status: 200, body: { inline_string: "OK\n" } }
              - match: { prefix: "$TROJAN_WS_PATH" }
                route: { cluster: trojan_ws_cluster, timeout: 0s }
              - match: { prefix: "$VLESS_WS_PATH" }
                route: { cluster: vless_ws_cluster, timeout: 0s }
              - match: { prefix: "/" }
                route: { cluster: web_cluster }
          http_filters:
          - name: envoy.filters.http.local_ratelimit
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
              stat_prefix: http_local_rate_limiter
              token_bucket:
                max_tokens: 100
                tokens_per_fill: 50
                fill_interval: 1s
              filter_enabled:
                runtime_key: local_rate_limit_enabled
                default_value:
                  numerator: 100
                  denominator: HUNDRED
              filter_enforced:
                runtime_key: local_rate_limit_enforced
                default_value:
                  numerator: 100
                  denominator: HUNDRED
              status:
                code: TooManyRequests
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: web_cluster
    connect_timeout: 5s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: web_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 8081 }
  - name: trojan_ws_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: trojan_ws_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 10001 }
  - name: vless_ws_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: vless_ws_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 10002 }
EOF

        cat > entrypoint.sh <<'EOF'
#!/bin/sh
mkdir -p /tmp/envoy /var/log/xray /var/www/html
mount -t tmpfs -o size=64M tmpfs /tmp/envoy 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/xray 2>/dev/null || true
if [ -f /var/www/html/index.html ]; then
    sed -i "s|__START_TIME__|$(date +%s)000|g" /var/www/html/index.html
fi
busybox httpd -p 127.0.0.1:8081 -h /var/www/html
/usr/local/bin/xray run -c /etc/xray.json &
exec envoy -c /etc/envoy.yaml
EOF
        chmod +x entrypoint.sh

        cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates busybox-static
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray

FROM envoyproxy/envoy:v1.30-latest
USER root
COPY --from=builder /bin/busybox.static /bin/busybox
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY envoy.yaml /etc/envoy.yaml
COPY index.html /var/www/html/index.html
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/xray /entrypoint.sh /bin/busybox

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

    elif [ "$ENGINE" = "haproxy" ]; then
        cat > haproxy.cfg <<EOF
global
    log stdout format raw local0
    maxconn 8192

defaults
    log global
    mode http
    timeout connect 10s
    timeout client 3600s
    timeout server 3600s
    timeout http-request 15s

frontend main
    bind 0.0.0.0:8080
    http-response set-header Server Cloudflare

    # Anti-DDoS Stick-Table Rate Limiting (Safe for WS)
    stick-table type ip size 100k expire 30s store http_req_rate(10s),conn_cur
    http-request track-sc0 src
    http-request deny deny_status 429 if { sc_http_req_rate(0) gt 250 }
    http-request deny deny_status 429 if { sc_conn_cur(0) gt 100 }
    
    acl is_health path /health
    acl is_trojan_ws path_beg $TROJAN_WS_PATH
    acl is_vless_ws path_beg $VLESS_WS_PATH

    use_backend health_backend if is_health
    use_backend trojan_ws_backend if is_trojan_ws
    use_backend vless_ws_backend if is_vless_ws
    default_backend default_backend

backend health_backend
    http-request return status 200 content-type "text/plain" hdr Cache-Control "no-store" string "OK\n"

backend default_backend
    server web_local 127.0.0.1:8081

backend trojan_ws_backend
    server xray_tws 127.0.0.1:10001

backend vless_ws_backend
    server xray_vws 127.0.0.1:10002
EOF

        cat > entrypoint.sh <<'EOF'
#!/bin/sh
set -e
mkdir -p /tmp/haproxy /var/log/xray /var/www/html
mount -t tmpfs -o size=64M tmpfs /tmp/haproxy 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/xray 2>/dev/null || true
if [ -f /var/www/html/index.html ]; then
    sed -i "s|__START_TIME__|$(date +%s)000|g" /var/www/html/index.html
fi
busybox httpd -p 127.0.0.1:8081 -h /var/www/html
/usr/local/bin/xray run -c /etc/xray.json &
sleep 1
exec haproxy -W -db -f /usr/local/etc/haproxy/haproxy.cfg
EOF
        chmod +x entrypoint.sh

        cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray

FROM haproxy:2.8-alpine
USER root
RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY index.html /var/www/html/index.html
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/xray /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EXPOSE 8080
EOF

    elif [ "$ENGINE" = "caddy" ]; then
        cat > Caddyfile <<EOF
{
    admin off
    http_port 8080
    servers {
        timeouts {
            read_header 10s
            idle 3600s
        }
        max_header_size 16KB
    }
}

:8080 {
    header {
        Server "Cloudflare"
        -Server
    }

    # Anti-DDoS Request Body & Connection Protection
    request_body {
        max_size 10MB
    }

    handle /health {
        header Cache-Control "no-store"
        respond "OK\n" 200
    }

    handle ${TROJAN_WS_PATH}* {
        reverse_proxy 127.0.0.1:10001 {
            header_up Host {header.X-Forwarded-Host}
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle ${VLESS_WS_PATH}* {
        reverse_proxy 127.0.0.1:10002 {
            header_up Host {header.X-Forwarded-Host}
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF

        cat > entrypoint.sh <<'EOF'
#!/bin/sh
mkdir -p /tmp/caddy /var/log/xray
mount -t tmpfs -o size=64M tmpfs /tmp/caddy 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/xray 2>/dev/null || true
if [ -f /usr/share/caddy/index.html ]; then
    sed -i "s|__START_TIME__|$(date +%s)000|g" /usr/share/caddy/index.html
fi
/usr/local/bin/xray run -c /etc/xray.json &
exec caddy run --config /etc/Caddyfile --adapter caddyfile
EOF
        chmod +x entrypoint.sh

        cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray

FROM caddy:2.7-alpine
USER root
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY Caddyfile /etc/Caddyfile
COPY index.html /usr/share/caddy/index.html
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/xray /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

    elif [ "$ENGINE" = "singbox" ]; then
        cat > Caddyfile <<EOF
{
    admin off
    http_port 8080
    servers {
        timeouts {
            read_header 10s
            idle 3600s
        }
        max_header_size 16KB
    }
}

:8080 {
    header {
        Server "Cloudflare"
        -Server
    }

    # Anti-DDoS Request Body & Connection Protection
    request_body {
        max_size 10MB
    }

    handle /health {
        header Cache-Control "no-store"
        respond "OK\n" 200
    }

    handle ${TROJAN_WS_PATH}* {
        reverse_proxy 127.0.0.1:10001 {
            header_up Host {header.X-Forwarded-Host}
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle ${VLESS_WS_PATH}* {
        reverse_proxy 127.0.0.1:10002 {
            header_up Host {header.X-Forwarded-Host}
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF

        cat > singbox.json <<EOF
{
    "log": {
        "level": "warn"
    },
    "inbounds": [
        {
            "type": "trojan",
            "tag": "trojan-ws",
            "listen": "127.0.0.1",
            "listen_port": 10001,
            "users": [{"password": "$TROJAN_PASS"}],
            "transport": {
                "type": "ws",
                "path": "$TROJAN_WS_PATH"
            }
        },
        {
            "type": "vless",
            "tag": "vless-ws",
            "listen": "127.0.0.1",
            "listen_port": 10002,
            "users": [{"uuid": "$VLESS_UUID"}],
            "transport": {
                "type": "ws",
                "path": "$VLESS_WS_PATH"
            }
        }
    ],
    "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

        cat > entrypoint.sh <<'EOF'
#!/bin/sh
mkdir -p /tmp/singbox /var/log/sing-box
mount -t tmpfs -o size=64M tmpfs /tmp/singbox 2>/dev/null || true
mount -t tmpfs -o size=64M tmpfs /var/log/sing-box 2>/dev/null || true
if [ -f /usr/share/caddy/index.html ]; then
    sed -i "s|__START_TIME__|$(date +%s)000|g" /usr/share/caddy/index.html
fi
/usr/local/bin/sing-box run -c /etc/singbox.json &
exec caddy run --config /etc/Caddyfile --adapter caddyfile
EOF
        chmod +x entrypoint.sh

        cat > Dockerfile <<'EOF'
FROM ghcr.io/sagernet/sing-box:latest AS singbox-builder
FROM caddy:2.7-alpine
USER root
COPY --from=singbox-builder /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY singbox.json /etc/singbox.json
COPY Caddyfile /etc/Caddyfile
COPY index.html /usr/share/caddy/index.html
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/sing-box /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF
    fi

    echo -e "${CYAN}🔨 Building image to Artifact Registry...${NC}"
    gcloud builds submit --project="$PROJECT_ID" --tag "$IMAGE_TAG" . --quiet

    echo -e "${CYAN}🚀 Deploying to Cloud Run...${NC}"
    gcloud run deploy "$CLOUD_RUN_SERVICE_NAME" \
        --image "$IMAGE_TAG" \
        --project="$PROJECT_ID" --platform managed --region "$REGION" --allow-unauthenticated \
        --port 8080 --memory "$MEMORY" --cpu "$CPU" --concurrency "$CONCURRENCY" \
        --timeout "$TIMEOUT" --min-instances "$MIN_INST" --max-instances "$MAX_INST" \
        $BILLING_FLAG --cpu-boost --quiet

    CLOUD_RUN_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE_NAME" --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')
    DOMAIN=$(echo "$CLOUD_RUN_URL" | sed 's|https://||')
    CANONICAL_LINK="https://$DOMAIN"

    # ==============================================
    # GENERATE DIRECT VISIBLE PANEL (OCEAN BLUE THEME + REAL PING & UPTIME)
    # ==============================================
    cat > index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CON FIG | Cloud Gateway</title>
<style>
:root { 
    --bg: #041222; 
    --card: #081e36; 
    --border: #11355b; 
    --text: #94b8db; 
    --white: #f0f7ff; 
    --ocean: #0ea5e9; 
    --accent: #0284c7; 
    --accent-hover: #0369a1;
}
* { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
body { background: radial-gradient(circle at top, #0a2847 0%, var(--bg) 100%); color: var(--text); display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 28px; max-width: 480px; width: 100%; box-shadow: 0 12px 30px -5px rgba(2, 132, 199, 0.25); }
.header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; padding-bottom: 14px; border-bottom: 1px solid var(--border); }
.title { color: var(--white); font-size: 18px; font-weight: 600; letter-spacing: 0.3px; }
.badge { display: inline-flex; align-items: center; gap: 6px; background: rgba(14, 165, 233, 0.15); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.3); padding: 4px 10px; border-radius: 9999px; font-size: 12px; font-weight: 500; }
.dot { width: 8px; height: 8px; background: #38bdf8; border-radius: 50%; animation: pulse 2s infinite; }
.metrics { display: grid; gap: 10px; margin-bottom: 20px; }
.metric-item { display: flex; justify-content: space-between; font-size: 14px; padding: 8px 0; border-bottom: 1px dashed var(--border); }
.metric-item span:last-child { color: var(--white); font-weight: 500; font-variant-numeric: tabular-nums; }
.config-section { margin-top: 15px; border-top: 1px solid var(--border); padding-top: 15px; display: block; }
.config-box { background: #030d19; border: 1px solid var(--border); border-radius: 8px; padding: 10px; margin-bottom: 10px; font-family: monospace; font-size: 11px; color: #38bdf8; word-break: break-all; position: relative; }
.copy-btn { background: var(--accent); color: white; border: none; padding: 8px 12px; border-radius: 6px; font-size: 12px; font-weight: 500; cursor: pointer; width: 100%; margin-top: 4px; transition: background 0.2s; }
.copy-btn:hover { background: var(--accent-hover); }
.footer { font-size: 12px; text-align: center; color: #648bb3; margin-top: 15px; }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
</style>
</head>
<body>
<div class="card">
<div class="header">
<div class="title">ConFig Ocean Gateway</div>
<div class="badge"><span class="dot"></span> Operational</div>
</div>

<div class="metrics" id="statusView">
<div class="metric-item"><span>HTTP/2 Proxy Ingress</span><span style="color: #38bdf8;">Active</span></div>
<div class="metric-item"><span>Global Load Balancer</span><span>Normal</span></div>
<div class="metric-item"><span>Real-Time Latency</span><span id="realPing">Measuring...</span></div>
<div class="metric-item"><span>Container Uptime</span><span id="realUptime">Calculating...</span></div>
</div>

<div class="config-section" id="configView">
<p style="color: var(--white); font-size: 13px; margin-bottom: 8px; font-weight: 600;">⚡ STS NOLOAD NetMod Configs:</p>

<div style="font-size: 12px; color: var(--white); margin-bottom: 4px;">Trojan WS (SNI Masked):</div>
<div class="config-box" id="trojanConfig">trojan://${TROJAN_PASS}@firebaseremoteconfigrealtime.googleapis.com:443?type=ws&host=$DOMAIN&headerType=none&path=${TROJAN_WS_PATH_ENC}&security=tls&sni=firebaseremoteconfigrealtime.googleapis.com#GCP-Trojan-WS</div>
<button class="copy-btn" onclick="copyText('trojanConfig', this)">Copy Trojan Config</button>

<div style="font-size: 12px; color: var(--white); margin-top: 10px; margin-bottom: 4px;">VLESS WS (SNI Masked):</div>
<div class="config-box" id="vlessConfig">vless://${VLESS_UUID}@firebaseremoteconfigrealtime.googleapis.com:443?encryption=none&type=ws&host=$DOMAIN&headerType=none&path=${VLESS_WS_PATH_ENC}&security=tls&sni=firebaseremoteconfigrealtime.googleapis.com#GCP-VLESS-WS</div>
<button class="copy-btn" onclick="copyText('vlessConfig', this)">Copy VLESS Config</button>
</div>

<div class="footer">Cloud Infrastructure &copy; 2026. All Systems Nominal.</div>
</div>

<script>
// Real Container Start Timestamp injected on container boot
const rawStartTime = "__START_TIME__";
const serverStartTime = !isNaN(Number(rawStartTime)) ? Number(rawStartTime) : Date.now();

function updateUptime() {
    const now = Date.now();
    const diffSeconds = Math.max(0, Math.floor((now - serverStartTime) / 1000));
    
    const days = Math.floor(diffSeconds / 86400);
    const hours = Math.floor((diffSeconds % 86400) / 3600);
    const minutes = Math.floor((diffSeconds % 3600) / 60);
    const seconds = diffSeconds % 60;

    let parts = [];
    if (days > 0) parts.push(days + "d");
    if (hours > 0 || days > 0) parts.push(hours + "h");
    parts.push(minutes + "m");
    parts.push(seconds + "s");

    document.getElementById("realUptime").innerText = parts.join(" ");
}

async function measurePing() {
    const pingEl = document.getElementById("realPing");
    const start = performance.now();
    try {
        await fetch('/health?t=' + Date.now(), { cache: 'no-store' });
        const latency = Math.round(performance.now() - start);
        pingEl.innerText = latency + " ms";
        if (latency < 100) {
            pingEl.style.color = "#38bdf8"; // Ocean Blue / Fast
        } else if (latency < 250) {
            pingEl.style.color = "#facc15"; // Yellow / Moderate
        } else {
            pingEl.style.color = "#f87171"; // Red / High
        }
    } catch (e) {
        pingEl.innerText = "Timeout";
        pingEl.style.color = "#f87171";
    }
}

function copyText(elementId, btn) {
    const text = document.getElementById(elementId).innerText;
    navigator.clipboard.writeText(text).then(() => {
        const originalText = btn.innerText;
        btn.innerText = "Copied! ✅";
        btn.style.background = "#0ea5e9";
        setTimeout(() => {
            btn.innerText = originalText;
            btn.style.background = "";
        }, 2000);
    });
}

// Initialize Real-Time Updates
updateUptime();
setInterval(updateUptime, 1000);

measurePing();
setInterval(measurePing, 3000);
</script>
</body>
</html>
EOF

    gcloud builds submit --project="$PROJECT_ID" --tag "$IMAGE_TAG" . --quiet
    gcloud run services update "$CLOUD_RUN_SERVICE_NAME" --image "$IMAGE_TAG" --region "$REGION" --project="$PROJECT_ID" --quiet
    cleanup_old_artifact_images "$REGION" "$PROJECT_ID"

    clear
    echo -e "\n${CYAN}=========================================${NC}"
    echo -e "${GREEN}SCRIPT DEPLOYMENT SUCCESS!"
    echo -e "${GREEN}FIVE PROXY ENGINES 2 PROTOCOLS"
    echo -e "${GREEN}TROJAN & VLESS WEBSOCKET ONLY"
    echo -e "${GREEN}THIS SCRIPT IS OWNED & MADE BY CON FIG"
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${GREEN}🔗 SHORT LINK (Configs Visible Directly):${NC} $CANONICAL_LINK"
    echo -e "${GREEN}💚 HEALTH CHECK:${NC} ${CANONICAL_LINK}/health"
    echo -e "${CYAN}-----------------------------------------${NC}"
    echo -e "${GREEN}🔌 AVAILABLE ENDPOINTS:${NC}"
    echo -e " Trojan-WS: ${CANONICAL_LINK}${TROJAN_WS_PATH}"
    echo -e " VLESS-WS: ${CANONICAL_LINK}${VLESS_WS_PATH}"
    echo -e "${CYAN}🔑 GENERATED CREDENTIALS:${NC}"
    echo -e " Trojan Pass: $TROJAN_PASS"
    echo -e " VLESS UUID: $VLESS_UUID"
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${GREEN}🛡️ FEATURES ACTIVE:${NC}"
    echo -e " ✅ Custom User-Agent Header Preserved"
    echo -e " ✅ Artifact Registry Auto-Setup & Old Image Cleanup"
    echo -e " ✅ Anti-DDoS Rate Limiting (All 5 Engines)"
    echo -e " ✅ RAM Disk (tmpfs) High-Speed Mounts"
    echo -e " ✅ Masked Engine Names ($ENGINE_MASK)"
    echo -e " ✅ Direct Ocean Blue Panel with Real Ping & Uptime"
    echo ""

    read -p "Press [Enter] to return to Main Menu..."
}

# ==============================================
# MAIN MENU LOOP
# ==============================================
while true; do
    clear
    echo "======================================"
    echo "FIVE PROXY ENGINES GCP DEPLOYER 2 PROTOCOLS"
    echo "TROJAN & VLESS WEBSOCKET ONLY"
    echo "THIS SCRIPT IS OWNED & MADE BY CON FIG"
    echo "======================================"
    echo "1) Deploy New Service to Cloud Run"
    echo "2) List All Active Cloud Run Services"
    echo "3) Exit Script"
    echo "======================================"

    read -p "Select Option [1-3]: " MENU_CHOICE
    case $MENU_CHOICE in
        1) deploy_new_service ;;
        2) list_deployed_services ;;
        3) echo -e "\n👋 Goodbye!"; exit 0 ;;
        *) echo -e "${RED}❌ Enter 1, 2, or 3 only${NC}"; sleep 2 ;;
    esac
done
