#!/usr/bin/env bash
# ============================================================================
# RIOS Telephony Bridge — Full Installation Script
# ============================================================================
# Installs inside a Debian 12 (Bookworm) LXC container:
#   1. FreeSWITCH (from source, v1.10 branch)
#   2. mod_audio_stream (WebSocket audio streaming)
#   3. Node.js 20 LTS + RIOS telephony bridge
#   4. systemd services for auto-restart
#   5. FreeSWITCH config for 3CX SIP registration
#
# Usage: bash install/rios-telephony-install.sh
#
# Designed for ARM64 (Raspberry Pi 5 / Proxmox on Pi) and AMD64.
# ============================================================================

set -euo pipefail

# Colors
BL='\033[36m'; GN='\033[32m'; RD='\033[31m'; YW='\033[33m'; CL='\033[0m'
msg_info() { echo -e "${BL}[INFO]${CL} $1"; }
msg_ok()   { echo -e "${GN}[OK]${CL} $1"; }
msg_error(){ echo -e "${RD}[ERROR]${CL} $1"; }

INSTALL_DIR="/opt/rios-telephony"
FS_PREFIX="/usr/local/freeswitch"
BRIDGE_DIR="${INSTALL_DIR}/bridge"
ARCH=$(dpkg --print-architecture)

header() {
  clear
  cat <<"EOF"
    ____  ________  _____
   / __ \/  _/ __ \/ ___/   Telephony Bridge
  / /_/ // // / / /\__ \    Installation Script
 / _, _// // /_/ /___/ /    FreeSWITCH + Node.js
/_/ |_/___/\____//____/     Debian 12

EOF
  echo -e "Architecture: ${GN}${ARCH}${CL}"
  echo ""
}

header

# ============================================================================
# 1. SYSTEM DEPENDENCIES
# ============================================================================
msg_info "Installing system dependencies..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential cmake git curl wget sudo \
  autoconf automake libtool pkg-config \
  libssl-dev zlib1g-dev libevent-dev libspeexdsp-dev \
  libcurl4-openssl-dev libpcre3-dev libspeex-dev \
  libedit-dev libsqlite3-dev libpq-dev \
  libavformat-dev libswscale-dev \
  liblua5.2-dev libopus-dev libsndfile1-dev \
  uuid-dev libldns-dev \
  python3 python3-dev \
  unixodbc-dev libshout3-dev libmpg123-dev libmp3lame-dev \
  yasm nasm libjpeg-dev \
  ca-certificates gnupg lsb-release \
  systemd \
  2>&1 | tail -5

msg_ok "System dependencies installed"

# ============================================================================
# 2. INSTALL NODE.JS 20 LTS
# ============================================================================
msg_info "Installing Node.js 20 LTS..."

if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs 2>&1 | tail -3
fi

NODE_VER=$(node --version)
msg_ok "Node.js ${NODE_VER} installed"

# ============================================================================
# 3. BUILD SOFIA-SIP (FreeSWITCH dependency)
# ============================================================================
msg_info "Building sofia-sip..."

cd /usr/src
if [ ! -d sofia-sip ]; then
  git clone https://github.com/freeswitch/sofia-sip.git
fi
cd sofia-sip
./bootstrap.sh
./configure --prefix=/usr/local
make -j$(nproc)
make install
ldconfig

msg_ok "sofia-sip installed"

# ============================================================================
# 4. BUILD SPANDSP (FreeSWITCH dependency)
# ============================================================================
msg_info "Building spandsp..."

cd /usr/src
if [ ! -d spandsp ]; then
  git clone https://github.com/freeswitch/spandsp.git
fi
cd spandsp
./bootstrap.sh
./configure --prefix=/usr/local
make -j$(nproc)
make install
ldconfig

msg_ok "spandsp installed"

# ============================================================================
# 5. BUILD FREESWITCH FROM SOURCE
# ============================================================================
msg_info "Building FreeSWITCH from source (v1.10 branch)..."
msg_info "This may take 15-45 minutes depending on hardware..."

cd /usr/src
if [ ! -d freeswitch ]; then
  git clone -b v1.10 https://github.com/signalwire/freeswitch.git
fi
cd freeswitch
git config pull.rebase true

# Configure modules - enable what we need, disable what we don't
cp modules.conf modules.conf.bak 2>/dev/null || true
cat > modules.conf << 'MODULES'
# Core modules
applications/mod_commands
applications/mod_dptools
applications/mod_expr
applications/mod_hash
applications/mod_spandsp
applications/mod_db
applications/mod_esf
applications/mod_fsv

# Codecs (must have for 3CX interop)
codecs/mod_amr
codecs/mod_g723_1
codecs/mod_g729
codecs/mod_opus

# Dialplan
dialplan/mod_dialplan_xml

# Endpoints
endpoints/mod_sofia
endpoints/mod_loopback

# Event handlers
event_handlers/mod_event_socket

# Formats
formats/mod_native_file
formats/mod_sndfile
formats/mod_tone_stream
formats/mod_local_stream

# Loggers
loggers/mod_console
loggers/mod_logfile

# Say (TTS number/date announcement)
say/mod_say_en

# XML interfaces
xml_int/mod_xml_rpc
MODULES

./bootstrap.sh -j
./configure --prefix=${FS_PREFIX}
make -j$(nproc)
make install

# Install default sounds (minimal)
make cd-sounds-install 2>/dev/null || true
make cd-moh-install 2>/dev/null || true

# Set permissions
if ! id -u freeswitch &>/dev/null; then
  useradd -r -s /usr/sbin/nologin freeswitch
fi
chown -R freeswitch:freeswitch ${FS_PREFIX}

# Add to PATH
cat > /etc/profile.d/freeswitch.sh << EOF
export PATH=\$PATH:${FS_PREFIX}/bin
EOF
export PATH=$PATH:${FS_PREFIX}/bin

msg_ok "FreeSWITCH built and installed at ${FS_PREFIX}"

# ============================================================================
# 6. BUILD & INSTALL mod_audio_stream
# ============================================================================
msg_info "Building mod_audio_stream..."

cd /usr/src
if [ ! -d mod_audio_stream ]; then
  git clone https://github.com/amigniter/mod_audio_stream.git
fi
cd mod_audio_stream
git submodule init
git submodule update

export PKG_CONFIG_PATH="${FS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)
make install

msg_ok "mod_audio_stream installed"

# Enable mod_audio_stream in FreeSWITCH
FS_MODULES_CONF="${FS_PREFIX}/etc/freeswitch/autoload_configs/modules.conf.xml"
if ! grep -q "mod_audio_stream" "${FS_MODULES_CONF}" 2>/dev/null; then
  # Add before closing </modules> tag
  sed -i '/<\/modules>/i\    <load module="mod_audio_stream"/>' "${FS_MODULES_CONF}"
  msg_ok "mod_audio_stream enabled in modules.conf.xml"
fi

# ============================================================================
# 7. CONFIGURE FREESWITCH FOR 3CX REGISTRATION
# ============================================================================
msg_info "Configuring FreeSWITCH for 3CX SIP registration..."

mkdir -p ${INSTALL_DIR}

# Create the SIP gateway configuration (user fills in 3CX details)
cat > "${FS_PREFIX}/etc/freeswitch/sip_profiles/external/3cx_gateway.xml" << 'SIPCONF'
<!--
  3CX SIP Gateway Configuration

  FreeSWITCH registers as a SIP extension on your 3CX PBX.
  This is the simplest approach - no SBC needed if on same LAN.

  Edit the variables below to match your 3CX extension credentials.
  After editing, run: fs_cli -x "sofia profile external restart"
-->
<include>
  <gateway name="3cx-rios">
    <!-- 3CX server IP or FQDN -->
    <param name="realm" value="CHANGE_ME_3CX_IP"/>
    <!-- SIP extension number (e.g., 1001) -->  
    <param name="username" value="CHANGE_ME_EXTENSION"/>
    <!-- SIP authentication password from 3CX extension config -->
    <param name="password" value="CHANGE_ME_PASSWORD"/>
    <!-- Registration settings -->
    <param name="register" value="true"/>
    <param name="register-transport" value="udp"/>
    <param name="expire-seconds" value="600"/>
    <param name="retry-seconds" value="30"/>
    <!-- Caller ID -->
    <param name="caller-id-in-from" value="true"/>
    <!-- Codec preference matching 3CX defaults -->
    <param name="codec-prefs" value="PCMA@8000h@20i,PCMU@8000h@20i,opus@48000h@20i"/>
    <!-- Proxy (usually same as realm for LAN setup) -->
    <param name="proxy" value="CHANGE_ME_3CX_IP"/>
    <!-- SIP port (3CX default is 5060) -->
    <param name="register-proxy" value="sip:CHANGE_ME_3CX_IP:5060"/>
  </gateway>
</include>

<!-- Example: 3CX Cloud (TLS) -->
<!--
  For 3CX Cloud hosting use TLS (5061). Update to your cloud FQDN and use TLS transport:
-->
<include>
  <gateway name="3cx-rios-cloud">
    <param name="realm" value="pbx.example.3cx.cloud"/>
    <param name="username" value="CHANGE_ME_EXTENSION"/>
    <param name="password" value="CHANGE_ME_PASSWORD"/>
    <param name="register" value="true"/>
    <param name="register-transport" value="tls"/>
    <param name="expire-seconds" value="600"/>
    <param name="proxy" value="pbx.example.3cx.cloud"/>
    <param name="register-proxy" value="sip:pbx.example.3cx.cloud:5061"/>
    <!-- If you encounter TLS verification errors: ensure CA certs are trusted on the system.
         For testing only you can disable verification with: <param name="verify-server" value="false"/> -->
  </gateway>
</include>

<!-- Example: Use local 3CX Remote SBC -->
<!--
  If using a 3CX Remote SBC installed on your LAN, set the gateway to point to the SBC IP
  and prefer TLS/TCP per your SBC configuration. The SBC will handle NAT traversal and media.
-->
<include>
  <gateway name="3cx-rios-sbc">
    <param name="realm" value="SBC_IP_OR_HOSTNAME"/>
    <param name="username" value="CHANGE_ME_EXTENSION"/>
    <param name="password" value="CHANGE_ME_PASSWORD"/>
    <param name="register" value="true"/>
    <param name="register-transport" value="tcp"/>
    <param name="proxy" value="SBC_IP_OR_HOSTNAME"/>
    <param name="register-proxy" value="sip:SBC_IP_OR_HOSTNAME:5061"/>
    <param name="codec-prefs" value="PCMA@8000h@20i,PCMU@8000h@20i"/>
  </gateway>
</include>
SIPCONF

# Create the dialplan to route incoming calls to the audio bridge
cat > "${FS_PREFIX}/etc/freeswitch/dialplan/default/9000_rios_bridge.xml" << 'DIALPLAN'
<!--
  RIOS AI Telephony Bridge Dialplan
  
  Routes ALL incoming calls from the 3CX gateway to the RIOS audio bridge.
  When someone calls the RIOS extension on 3CX, this answers and streams
  audio bidirectionally to the Node.js bridge via WebSocket.
-->
<include>
  <!-- Inbound from 3CX: answer and bridge to RIOS -->
  <extension name="rios-ai-bridge">
    <condition field="destination_number" expression="^(.*)$">
      <action application="answer"/>
      <action application="sleep" data="500"/>
      <!-- Set audio parameters -->
      <action application="set" data="STREAM_BUFFER_SIZE=20"/>
      <action application="set" data="STREAM_NO_RECONNECT=false"/>
      <!-- 
        Start bidirectional audio streaming to local Node.js bridge.
        The bridge WebSocket runs on localhost:8765
        'mixed' = send both caller audio and any playback
        16000 = 16kHz sample rate (Gemini expects 16kHz)
      -->
      <action application="uuid_audio_stream" data="${uuid} start ws://127.0.0.1:8765 mixed 16000"/>
      <!-- Keep the call alive - the bridge controls hangup -->
      <action application="park"/>
    </condition>
  </extension>

  <!-- Outbound: RIOS initiates a call -->
  <extension name="rios-outbound">
    <condition field="destination_number" expression="^9(\d+)$">
      <action application="set" data="effective_caller_id_number=RIOS"/>
      <action application="set" data="effective_caller_id_name=RIOS AI"/>
      <action application="bridge" data="sofia/gateway/3cx-rios/$1"/>
    </condition>
  </extension>
</include>
DIALPLAN

# Configure event socket (ESL) for Node.js control
cat > "${FS_PREFIX}/etc/freeswitch/autoload_configs/event_socket.conf.xml" << 'ESLCONF'
<configuration name="event_socket.conf" description="Socket Client">
  <settings>
    <!-- Listen on localhost only for security -->
    <param name="nat-map" value="false"/>
    <param name="listen-ip" value="127.0.0.1"/>
    <param name="listen-port" value="8021"/>
    <param name="password" value="ClueCon"/>
    <param name="apply-inbound-acl" value="loopback.auto"/>
  </settings>
</configuration>
ESLCONF

msg_ok "FreeSWITCH configured for 3CX"

# ============================================================================
# 8. CREATE RIOS TELEPHONY BRIDGE (NODE.JS)
# ============================================================================
msg_info "Creating RIOS telephony bridge..."

mkdir -p ${BRIDGE_DIR}

# package.json
cat > "${BRIDGE_DIR}/package.json" << 'PKGJSON'
{
  "name": "rios-telephony-bridge",
  "version": "1.0.0",
  "description": "RIOS AI Telephony Bridge - FreeSWITCH to Gemini Live",
  "type": "module",
  "main": "bridge.mjs",
  "scripts": {
    "start": "node bridge.mjs",
    "dev": "node --watch bridge.mjs"
  },
  "dependencies": {
    "@google/genai": "^1.1.0",
    "ws": "^8.16.0",
    "express": "^4.18.0",
    "dotenv": "^16.4.0"
  }
}
PKGJSON

# .env template
cat > "${BRIDGE_DIR}/.env" << 'ENVFILE'
# ============================================================================
# RIOS Telephony Bridge Configuration
# ============================================================================

# Google Gemini API Key (REQUIRED)
GOOGLE_API_KEY=CHANGE_ME

# FreeSWITCH ESL connection
ESL_HOST=127.0.0.1
ESL_PORT=8021
ESL_PASSWORD=ClueCon

# WebSocket server for audio streaming (mod_audio_stream connects here)
WS_AUDIO_PORT=8765

# REST API port (RIOS frontend connects here)
API_PORT=8080

# RIOS server URL (for forwarding tool results)
RIOS_SERVER_URL=http://YOUR_RIOS_IP:8000

# Gemini Live model
GEMINI_MODEL=gemini-2.5-flash-native-audio-preview-09-2025

# Voice preference
VOICE_NAME=Charon

# 3CX SIP settings (informational - actual config in FreeSWITCH XML)
SIP_EXTENSION=CHANGE_ME
SIP_SERVER=CHANGE_ME
ENVFILE

# The main bridge application
cat > "${BRIDGE_DIR}/bridge.mjs" << 'BRIDGE_MJS'
/**
 * RIOS Telephony Bridge
 * 
 * Connects FreeSWITCH audio (via mod_audio_stream WebSocket) to Google Gemini
 * Live API for real-time AI voice conversation over phone calls.
 * 
 * Architecture:
 *   Phone Call -> 3CX PBX -> FreeSWITCH (SIP) -> mod_audio_stream (WS)
 *                -> THIS BRIDGE -> Gemini Live API (bidirectional audio)
 *                -> mod_audio_stream (WS playback) -> FreeSWITCH -> Phone
 * 
 * Components:
 *   1. WebSocket Server (port 8765) - receives audio from FreeSWITCH
 *   2. Gemini Live Session - bidirectional audio AI
 *   3. REST API (port 8080) - control plane for RIOS frontend
 *   4. Tool execution - weather, Home Assistant, Spotify via RIOS server
 */

import { GoogleGenAI, Modality } from '@google/genai';
import { WebSocketServer, WebSocket } from 'ws';
import express from 'express';
import { readFileSync } from 'fs';
import { config } from 'dotenv';

config(); // Load .env

// ============================================================================
// CONFIGURATION
// ============================================================================
const GOOGLE_API_KEY = process.env.GOOGLE_API_KEY || '';
const WS_AUDIO_PORT = parseInt(process.env.WS_AUDIO_PORT || '8765');
const API_PORT = parseInt(process.env.API_PORT || '8080');
const GEMINI_MODEL = process.env.GEMINI_MODEL || 'gemini-2.5-flash-native-audio-preview-09-2025';
const VOICE_NAME = process.env.VOICE_NAME || 'Charon';
const RIOS_SERVER_URL = process.env.RIOS_SERVER_URL || 'http://localhost:8000';

if (!GOOGLE_API_KEY || GOOGLE_API_KEY === 'CHANGE_ME') {
  console.error('[BRIDGE] ERROR: GOOGLE_API_KEY not set in .env');
  process.exit(1);
}

const ai = new GoogleGenAI({ apiKey: GOOGLE_API_KEY });

// ============================================================================
// STATE
// ============================================================================
const activeCalls = new Map(); // uuid -> { fsWs, geminiSession, startTime }
let bridgeStats = { totalCalls: 0, activeCalls: 0, errors: 0, uptime: Date.now() };

// ============================================================================
// SYSTEM INSTRUCTION (same as RIOS but adapted for phone)
// ============================================================================
const PHONE_SYSTEM_INSTRUCTION = `You are RIOS, a highly intelligent AI assistant answering a phone call.
You are speaking via telephone - the caller has dialed your extension on the office phone system.

PERSONA: You are a loyal, professional British butler-style assistant. Efficient, polite, and proper. Address the caller as "Sir" or "Ma'am".

IMPORTANT PHONE ETIQUETTE:
- You are on a PHONE CALL. Keep responses concise and conversational.
- Do NOT use markdown, links, or visual formatting - the caller can only HEAR you.
- Speak naturally as if on a phone. Use verbal cues like "Certainly, sir" or "Right away".
- If asked about something visual (like showing an image), explain you're on a phone call.
- When the caller says "goodbye", "hang up", or "that's all", use the end_session tool.

AVAILABLE CAPABILITIES (you can execute these via phone):
- Weather: Get current weather for any city
- Home Assistant: Control smart home devices (lights, switches, media players)
- Spotify: Play/pause/skip music, change volume, transfer playback to devices
- General knowledge: Answer questions using your training data

TOOL EXECUTION:
- Execute tools IMMEDIATELY when requested. Don't narrate plans.
- After executing a tool, summarize the result verbally for the caller.
- For Home Assistant: use hass_call_service and hass_get_state
- For Spotify: use the spotify tools (playMusic, pauseMusic, etc.)
- For weather: use the weather tool

EXAMPLE INTERACTIONS:
- "Turn off the lights in my room" → call hass_call_service(light, turn_off, light.bedroom)
- "What's the weather like?" → call weather(city) → speak the result
- "Play some jazz music" → call playMusic(jazz) → confirm to caller
- "Put music on the TV" → call fetchDevices → find TV → transferPlayback → confirm
`;

// ============================================================================
// TOOL DECLARATIONS (subset for phone use)
// ============================================================================
const PHONE_TOOLS = [
  {
    functionDeclarations: [
      {
        name: "weather",
        description: "Get current weather for a city.",
        parameters: {
          type: "OBJECT",
          properties: { city: { type: "STRING" } },
          required: ["city"]
        }
      },
      {
        name: "hass_get_state",
        description: "Get state of Home Assistant entities.",
        parameters: {
          type: "OBJECT",
          properties: { entity_id: { type: "STRING" } },
          required: []
        }
      },
      {
        name: "hass_call_service",
        description: "Call a Home Assistant service to control devices.",
        parameters: {
          type: "OBJECT",
          properties: {
            domain: { type: "STRING" },
            service: { type: "STRING" },
            entity_id: { type: "STRING" },
            service_data: { type: "STRING" }
          },
          required: ["domain", "service", "entity_id"]
        }
      },
      {
        name: "playMusic",
        description: "Plays music on Spotify.",
        parameters: {
          type: "OBJECT",
          properties: { query: { type: "STRING" } },
          required: ["query"]
        }
      },
      {
        name: "pauseMusic",
        description: "Pauses Spotify playback.",
        parameters: { type: "OBJECT", properties: {}, required: [] }
      },
      {
        name: "resumeMusic",
        description: "Resumes Spotify playback.",
        parameters: { type: "OBJECT", properties: {}, required: [] }
      },
      {
        name: "nextTrack",
        description: "Skip to next track.",
        parameters: { type: "OBJECT", properties: {}, required: [] }
      },
      {
        name: "setVolume",
        description: "Set Spotify volume (0-100).",
        parameters: {
          type: "OBJECT",
          properties: { level: { type: "INTEGER" } },
          required: ["level"]
        }
      },
      {
        name: "getMusicStatus",
        description: "Get current playing track info.",
        parameters: { type: "OBJECT", properties: {}, required: [] }
      },
      {
        name: "fetchDevices",
        description: "List available Spotify Connect devices.",
        parameters: { type: "OBJECT", properties: {}, required: [] }
      },
      {
        name: "transferPlayback",
        description: "Transfer Spotify playback to a device by ID.",
        parameters: {
          type: "OBJECT",
          properties: { deviceId: { type: "STRING" } },
          required: ["deviceId"]
        }
      },
      {
        name: "end_session",
        description: "End the phone call. Use when caller says goodbye or hang up.",
        parameters: { type: "OBJECT", properties: {}, required: [] }
      }
    ]
  }
];

// ============================================================================
// TOOL EXECUTION (proxy to RIOS server or execute locally)
// ============================================================================
async function executeTool(name, args) {
  console.log(`[TOOL] Executing: ${name}`, JSON.stringify(args));
  
  try {
    switch (name) {
      case 'weather': {
        const res = await fetch(`https://wttr.in/${encodeURIComponent(args.city || 'London')}?format=j1`);
        const data = await res.json();
        const current = data.current_condition?.[0];
        if (current) {
          return `Weather in ${args.city}: ${current.weatherDesc?.[0]?.value || 'Unknown'}, ` +
                 `Temperature: ${current.temp_C}°C (${current.temp_F}°F), ` +
                 `Humidity: ${current.humidity}%, Wind: ${current.windspeedKmph} km/h`;
        }
        return await res.text();
      }

      case 'hass_get_state':
      case 'hass_call_service': {
        // Proxy to RIOS server which has HASS credentials
        const res = await fetch(`${RIOS_SERVER_URL}/api/telephony/tool`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ tool: name, args })
        });
        if (res.ok) {
          return await res.text();
        }
        return `Tool ${name} failed: ${res.statusText}`;
      }

      case 'playMusic':
      case 'pauseMusic':
      case 'resumeMusic':
      case 'nextTrack':
      case 'setVolume':
      case 'getMusicStatus':
      case 'fetchDevices':
      case 'transferPlayback': {
        // Proxy to RIOS server which has Spotify credentials
        const res = await fetch(`${RIOS_SERVER_URL}/api/telephony/tool`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ tool: name, args })
        });
        if (res.ok) {
          return await res.text();
        }
        return `Tool ${name} failed: ${res.statusText}`;
      }

      case 'end_session':
        return 'CALL_END_REQUESTED';

      default:
        return `Unknown tool: ${name}`;
    }
  } catch (e) {
    console.error(`[TOOL] Error executing ${name}:`, e.message);
    return `Tool error: ${e.message}`;
  }
}

// ============================================================================
// GEMINI LIVE SESSION MANAGER
// ============================================================================
async function createGeminiSession(callUuid, onAudioOutput, onSessionEnd) {
  console.log(`[GEMINI] Creating live session for call ${callUuid}`);

  const session = await ai.live.connect({
    model: GEMINI_MODEL,
    config: {
      tools: PHONE_TOOLS,
      systemInstruction: PHONE_SYSTEM_INSTRUCTION,
      responseModalities: [Modality.AUDIO],
      inputAudioTranscription: {},
      outputAudioTranscription: {},
      speechConfig: {
        voiceConfig: { prebuiltVoiceConfig: { voiceName: VOICE_NAME } }
      }
    },
    callbacks: {
      onopen: () => {
        console.log(`[GEMINI] Session open for call ${callUuid}`);
      },
      onmessage: async (msg) => {
        // Handle audio output -> send back to FreeSWITCH
        const audioData = msg.serverContent?.modelTurn?.parts?.[0]?.inlineData?.data;
        if (audioData) {
          onAudioOutput(audioData);
        }

        // Handle transcriptions (for logging)
        if (msg.serverContent?.outputTranscription?.text) {
          console.log(`[GEMINI] RIOS: ${msg.serverContent.outputTranscription.text}`);
        }
        if (msg.serverContent?.inputTranscription?.text) {
          console.log(`[GEMINI] Caller: ${msg.serverContent.inputTranscription.text}`);
        }

        // Handle tool calls
        if (msg.toolCall?.functionCalls) {
          for (const fc of msg.toolCall.functionCalls) {
            const result = await executeTool(fc.name, fc.args || {});
            
            // Handle end_session specially
            if (result === 'CALL_END_REQUESTED') {
              console.log(`[GEMINI] End session requested for call ${callUuid}`);
              // Let Gemini finish speaking first, then end
              setTimeout(() => onSessionEnd(callUuid), 3000);
            }
            
            // Send tool response back to Gemini
            try {
              session.sendToolResponse({
                functionResponses: [{
                  id: fc.id,
                  name: fc.name,
                  response: { result: result }
                }]
              });
            } catch (e) {
              console.error(`[GEMINI] Error sending tool response:`, e.message);
            }
          }
        }
      },
      onerror: (e) => {
        console.error(`[GEMINI] Error for call ${callUuid}:`, e.message || e);
        bridgeStats.errors++;
      },
      onclose: () => {
        console.log(`[GEMINI] Session closed for call ${callUuid}`);
      }
    }
  });

  return session;
}

// ============================================================================
// AUDIO FORMAT CONVERSION
// ============================================================================

/**
 * Convert L16 (16-bit signed PCM, little-endian) from FreeSWITCH 
 * to base64 for Gemini Live API input.
 * FreeSWITCH mod_audio_stream sends raw L16 binary at the configured sample rate.
 */
function l16ToBase64(buffer) {
  return Buffer.from(buffer).toString('base64');
}

/**
 * Convert base64 PCM from Gemini (24kHz 16-bit LE) to L16 binary
 * and resample to 16kHz for FreeSWITCH playback.
 * 
 * Gemini outputs 24kHz, FreeSWITCH expects 16kHz on the call leg.
 */
function geminiAudioToL16(base64Audio) {
  const inputBuffer = Buffer.from(base64Audio, 'base64');
  const inputSamples = new Int16Array(inputBuffer.buffer, inputBuffer.byteOffset, inputBuffer.length / 2);
  
  // Resample 24kHz -> 16kHz (ratio 3:2)
  const ratio = 24000 / 16000; // 1.5
  const outputLength = Math.floor(inputSamples.length / ratio);
  const outputSamples = new Int16Array(outputLength);
  
  for (let i = 0; i < outputLength; i++) {
    const srcIdx = i * ratio;
    const idx = Math.floor(srcIdx);
    const frac = srcIdx - idx;
    
    if (idx + 1 < inputSamples.length) {
      // Linear interpolation
      outputSamples[i] = Math.round(
        inputSamples[idx] * (1 - frac) + inputSamples[idx + 1] * frac
      );
    } else {
      outputSamples[i] = inputSamples[idx] || 0;
    }
  }
  
  return Buffer.from(outputSamples.buffer);
}

// ============================================================================
// WEBSOCKET AUDIO SERVER (FreeSWITCH mod_audio_stream connects here)
// ============================================================================
const wss = new WebSocketServer({ port: WS_AUDIO_PORT });

wss.on('connection', async (ws, req) => {
  // mod_audio_stream connects with the call UUID in the URL path or headers
  const callUuid = req.url?.replace('/', '') || `call-${Date.now()}`;
  console.log(`[WS] FreeSWITCH connected for call: ${callUuid}`);
  
  bridgeStats.totalCalls++;
  bridgeStats.activeCalls++;

  let geminiSession = null;
  let isClosing = false;
  
  const endCall = async (uuid) => {
    if (isClosing) return;
    isClosing = true;
    console.log(`[BRIDGE] Ending call ${uuid}`);
    
    try {
      if (geminiSession) {
        geminiSession.close();
        geminiSession = null;
      }
    } catch (e) {}
    
    try {
      if (ws.readyState === WebSocket.OPEN) {
        ws.close();
      }
    } catch (e) {}
    
    activeCalls.delete(uuid);
    bridgeStats.activeCalls = Math.max(0, bridgeStats.activeCalls - 1);
    console.log(`[BRIDGE] Call ${uuid} ended. Active calls: ${bridgeStats.activeCalls}`);
  };

  try {
    // Create Gemini Live session for this call
    geminiSession = await createGeminiSession(
      callUuid,
      // onAudioOutput: send Gemini's speech back to FreeSWITCH
      (base64Audio) => {
        if (ws.readyState === WebSocket.OPEN && !isClosing) {
          try {
            const l16Buffer = geminiAudioToL16(base64Audio);
            ws.send(l16Buffer);
          } catch (e) {
            console.error(`[WS] Error sending audio to FreeSWITCH:`, e.message);
          }
        }
      },
      // onSessionEnd: Gemini requested call termination
      endCall
    );

    activeCalls.set(callUuid, {
      fsWs: ws,
      geminiSession,
      startTime: Date.now()
    });

    console.log(`[BRIDGE] Call ${callUuid} bridged. Active calls: ${bridgeStats.activeCalls}`);

  } catch (e) {
    console.error(`[BRIDGE] Failed to create Gemini session for ${callUuid}:`, e.message);
    bridgeStats.errors++;
    ws.close();
    bridgeStats.activeCalls = Math.max(0, bridgeStats.activeCalls - 1);
    return;
  }

  // Handle incoming audio from FreeSWITCH
  ws.on('message', (data) => {
    if (isClosing || !geminiSession) return;
    
    try {
      // mod_audio_stream sends raw L16 binary audio
      if (Buffer.isBuffer(data)) {
        const base64Audio = l16ToBase64(data);
        geminiSession.sendRealtimeInput({
          media: {
            data: base64Audio,
            mimeType: 'audio/pcm;rate=16000'
          }
        });
      } else if (typeof data === 'string') {
        // mod_audio_stream may send JSON events (connect/disconnect)
        try {
          const event = JSON.parse(data);
          console.log(`[WS] Event from FreeSWITCH:`, event);
          if (event.event === 'disconnect' || event.event === 'end') {
            endCall(callUuid);
          }
        } catch (e) {
          // Not JSON, might be text data - ignore
        }
      }
    } catch (e) {
      console.error(`[WS] Error processing audio:`, e.message);
    }
  });

  ws.on('close', () => {
    console.log(`[WS] FreeSWITCH disconnected for call: ${callUuid}`);
    endCall(callUuid);
  });

  ws.on('error', (err) => {
    console.error(`[WS] Error for call ${callUuid}:`, err.message);
    endCall(callUuid);
  });
});

console.log(`[BRIDGE] WebSocket audio server listening on port ${WS_AUDIO_PORT}`);

// ============================================================================
// REST API (RIOS frontend and monitoring)
// ============================================================================
const app = express();
app.use(express.json());

// CORS for RIOS frontend
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(200);
  next();
});

// Health check
app.get('/api/health', (req, res) => {
  res.json({
    status: 'ok',
    uptime: Math.floor((Date.now() - bridgeStats.uptime) / 1000),
    activeCalls: bridgeStats.activeCalls,
    totalCalls: bridgeStats.totalCalls,
    errors: bridgeStats.errors
  });
});

// Get bridge status
app.get('/api/status', (req, res) => {
  const calls = [];
  for (const [uuid, call] of activeCalls) {
    calls.push({
      uuid,
      duration: Math.floor((Date.now() - call.startTime) / 1000),
      active: true
    });
  }
  res.json({
    bridge: 'online',
    activeCalls: calls,
    stats: bridgeStats
  });
});

// Initiate outbound call (RIOS frontend can trigger this)
app.post('/api/call', async (req, res) => {
  const { destination } = req.body;
  if (!destination) {
    return res.status(400).json({ error: 'destination required' });
  }
  
  try {
    // Use ESL to originate a call via FreeSWITCH
    // The call will route through the dialplan and connect back to our WS
    const eslCmd = `originate sofia/gateway/3cx-rios/${destination} &park()`;
    
    // Simple ESL command via TCP
    const result = await sendEslCommand(eslCmd);
    res.json({ status: 'calling', destination, result });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Hangup a specific call
app.post('/api/hangup', async (req, res) => {
  const { uuid } = req.body;
  if (!uuid) {
    return res.status(400).json({ error: 'uuid required' });
  }
  
  const call = activeCalls.get(uuid);
  if (call) {
    try {
      await sendEslCommand(`uuid_kill ${uuid}`);
    } catch (e) {}
    res.json({ status: 'hangup_sent', uuid });
  } else {
    res.status(404).json({ error: 'call not found' });
  }
});

// Hangup all calls
app.post('/api/hangup-all', async (req, res) => {
  for (const [uuid] of activeCalls) {
    try {
      await sendEslCommand(`uuid_kill ${uuid}`);
    } catch (e) {}
  }
  res.json({ status: 'hangup_all_sent', count: activeCalls.size });
});

app.listen(API_PORT, '0.0.0.0', () => {
  console.log(`[BRIDGE] REST API listening on port ${API_PORT}`);
});

// ============================================================================
// SIMPLE ESL CLIENT (Event Socket Layer)
// ============================================================================
import { createConnection } from 'net';

function sendEslCommand(command) {
  return new Promise((resolve, reject) => {
    const host = process.env.ESL_HOST || '127.0.0.1';
    const port = parseInt(process.env.ESL_PORT || '8021');
    const password = process.env.ESL_PASSWORD || 'ClueCon';
    
    const socket = createConnection({ host, port }, () => {
      let buffer = '';
      let authenticated = false;
      let commandSent = false;
      
      socket.on('data', (data) => {
        buffer += data.toString();
        
        if (!authenticated && buffer.includes('Content-Type: auth/request')) {
          socket.write(`auth ${password}\n\n`);
          buffer = '';
        } else if (!authenticated && buffer.includes('Reply-Text: +OK accepted')) {
          authenticated = true;
          buffer = '';
          socket.write(`api ${command}\n\n`);
          commandSent = true;
        } else if (commandSent && buffer.includes('\n\n')) {
          // Extract response body
          const parts = buffer.split('\n\n');
          const body = parts.length > 1 ? parts[parts.length - 1] : buffer;
          socket.end();
          resolve(body.trim());
        }
      });
      
      socket.on('error', reject);
      socket.setTimeout(5000, () => {
        socket.destroy();
        reject(new Error('ESL timeout'));
      });
    });
    
    socket.on('error', reject);
  });
}

// ============================================================================
// STARTUP
// ============================================================================
console.log(`
╔════════════════════════════════════════════╗
║     RIOS Telephony Bridge v1.0.0          ║
║                                           ║
║  Audio WS:  ws://0.0.0.0:${WS_AUDIO_PORT}            ║
║  REST API:  http://0.0.0.0:${API_PORT}           ║
║  Gemini:    ${GEMINI_MODEL.substring(0, 30)}...  ║
║  Voice:     ${VOICE_NAME}                        ║
╚════════════════════════════════════════════╝
`);

// Graceful shutdown
process.on('SIGINT', () => {
  console.log('\n[BRIDGE] Shutting down...');
  for (const [uuid, call] of activeCalls) {
    try { call.geminiSession?.close(); } catch(e) {}
    try { call.fsWs?.close(); } catch(e) {}
  }
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('\n[BRIDGE] SIGTERM received, shutting down...');
  process.exit(0);
});
BRIDGE_MJS

# Install Node.js dependencies
cd ${BRIDGE_DIR}
npm install --production 2>&1 | tail -5

msg_ok "RIOS telephony bridge created at ${BRIDGE_DIR}"

# ============================================================================
# 9. CREATE SYSTEMD SERVICES
# ============================================================================
msg_info "Creating systemd services..."

# FreeSWITCH service
cat > /etc/systemd/system/freeswitch.service << FSSERVICE
[Unit]
Description=FreeSWITCH
After=network.target

[Service]
Type=forking
PIDFile=${FS_PREFIX}/run/freeswitch.pid
ExecStart=${FS_PREFIX}/bin/freeswitch -u freeswitch -g freeswitch -ncwait -nonat
ExecStop=${FS_PREFIX}/bin/freeswitch -stop
Restart=always
RestartSec=5
LimitNOFILE=65536
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
FSSERVICE

# RIOS Bridge service
cat > /etc/systemd/system/rios-bridge.service << BRIDGESERVICE
[Unit]
Description=RIOS Telephony Bridge
After=network.target freeswitch.service
Requires=freeswitch.service

[Service]
Type=simple
User=root
WorkingDirectory=${BRIDGE_DIR}
ExecStart=/usr/bin/node ${BRIDGE_DIR}/bridge.mjs
Restart=always
RestartSec=3
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
BRIDGESERVICE

systemctl daemon-reload
systemctl enable freeswitch
systemctl enable rios-bridge

msg_ok "systemd services created and enabled"

# ============================================================================
# 10. CREATE SETUP GUIDE
# ============================================================================
cat > "${INSTALL_DIR}/3CX-SETUP.md" << 'SETUPGUIDE'
# 3CX Setup Guide for RIOS Telephony Bridge

## Step 1: Create a SIP Extension in 3CX

1. Log into your 3CX Management Console
2. Go to **Extensions** → **Add Extension**
3. Create a new extension (e.g., extension 1099 "RIOS AI")
4. Note down these credentials:
   - **Extension Number** (e.g., 1099)
   - **Authentication ID** (usually same as extension)
   - **Authentication Password** (auto-generated or set your own)
   - **SIP Server IP / FQDN** (your 3CX server / cloud FQDN)

## Step 2: Configure FreeSWITCH Gateway

Edit the 3CX gateway config:
```bash
nano /usr/local/freeswitch/etc/freeswitch/sip_profiles/external/3cx_gateway.xml
```

Replace the CHANGE_ME values (examples below):
- `CHANGE_ME_3CX_IP` → Your 3CX server IP (e.g., 192.168.1.10) or cloud FQDN (e.g., pbx.example.3cx.cloud)
- `CHANGE_ME_EXTENSION` → The extension number (e.g., 1099)
- `CHANGE_ME_PASSWORD` → The SIP authentication password

### 3CX Cloud (TLS) notes
If you use a 3CX Cloud PBX, prefer TLS (port 5061):
- Set `register-transport` to `tls`
- Set `register-proxy` to `sip:pbx.example.3cx.cloud:5061`
- Ensure the system trusts the 3CX TLS certificate (add CA to system trust if required)
- If you see TLS verification issues, double-check dates, CA chain, or for testing only use `verify-server` false (not recommended for production)

## Step 3: Configure the Bridge

Edit the bridge environment:
```bash
nano /opt/rios-telephony/bridge/.env
```

Set at minimum:
- `GOOGLE_API_KEY` → Your Google Gemini API key
- `RIOS_SERVER_URL` → URL of your RIOS server (e.g., http://192.168.1.100:8000 or http://127.0.0.1:8000 if local)
- `SIP_EXTENSION` → Same extension number
- `SIP_SERVER` → Same 3CX server IP / FQDN

## Step 4: Start Services

```bash
# Start FreeSWITCH
systemctl start freeswitch

# Verify FreeSWITCH is running
fs_cli -x "status"

# Check SIP registration
fs_cli -x "sofia status gateway 3cx-rios"
# Should show: State: REGED (registered)

# Start the bridge
systemctl start rios-bridge

# Check bridge status
curl http://localhost:8080/api/health
```

## Step 5: Test the Call

1. Pick up any phone connected to your 3CX system
2. Dial the RIOS extension number (e.g., 1099)
3. You should hear RIOS answer after a brief pause
4. Try saying: "What's the weather like in London?"
5. Try: "Turn off the lights in my bedroom"
6. Say "Goodbye" to end the call

## Troubleshooting

### Check FreeSWITCH logs:
```bash
tail -f /usr/local/freeswitch/log/freeswitch.log
```

### Check bridge logs:
```bash
journalctl -u rios-bridge -f
```

### Check SIP registration:
```bash
fs_cli -x "sofia status gateway 3cx-rios"
```

### Common issues:
- **NOREG (not registered)**: Check 3CX IP/FQDN, credentials, transport, and firewall
- **TLS problems**: Verify the system trusts the remote certificate; if in doubt, test with TCP then switch to TLS
- **No audio**: Check mod_audio_stream is loaded: `fs_cli -x "module_exists mod_audio_stream"`
- **Bridge errors**: Check GOOGLE_API_KEY is set correctly in .env
- **Tools not working**: Check RIOS_SERVER_URL is reachable from the bridge container

## Network Requirements

The LXC container needs outbound access to:
- **SIP signaling**: UDP 5060 or TCP/TLS 5061 (cloud)
- **RTP media**: UDP 9000-10999 (or media ports used by SBC)
- **HTTPS**: generativelanguage.googleapis.com (Gemini API)
- **TCP 8080**: inbound for bridge API (from RIOS server)
- Ports 8765 are localhost only (internal audio bridge)

## Using 3CX SBC (recommended when FreeSWITCH is not on same LAN)

A 3CX Remote SBC (Session Border Controller) is recommended if your FreeSWITCH instance sits behind NAT or a firewall and cannot accept inbound SIP/RTP. The SBC maintains an outbound persistent connection to 3CX Cloud and handles NAT, media relay and security.

### Quick SBC setup checklist
1. In the 3CX Management Console, go to **Settings → SBC** (or Deployment → Remote Sites) and download the SBC installer for your platform.
2. Install the SBC on a host inside your LAN (or inside the same LXC network) and follow the 3CX installer steps.
3. In 3CX, configure the remote site or trunk to associate the SBC with your PBX and extensions.
4. Point the FreeSWITCH gateway (`realm`/`proxy`/`register-proxy`) to the **SBC IP** or local hostname, e.g., `sip:192.168.1.50:5061`.
5. Use `register-transport` `tcp` or `tls` depending on SBC settings; verify registration with `fs_cli`.
6. Ensure your firewall allows outbound TLS/TCP to the 3CX cloud (SBC establishes outbound connections); on local network allow SIP/TLS and RTP to the SBC.

### Example FreeSWITCH gateway when using SBC
```xml
<param name="realm" value="192.168.1.50"/>
<param name="username" value="1099"/>
<param name="password" value="SECRET"/>
<param name="register" value="true"/>
<param name="register-transport" value="tcp"/>
<param name="register-proxy" value="sip:192.168.1.50:5061"/>
```

### Final notes
- No code changes are required in the bridge itself to use an SBC — you only update the FreeSWITCH gateway and ensure the network routing/ports are correct.
- If the SBC performs media relay, FreeSWITCH will still use mod_audio_stream locally for the bridge; media between the phone and SBC is handled by the SBC/FreeSWITCH as normal.
SETUPGUIDE

msg_ok "Setup guide created at ${INSTALL_DIR}/3CX-SETUP.md"

# ============================================================================
# DONE
# ============================================================================
echo ""
echo "============================================================================"
msg_ok "RIOS Telephony Bridge installation complete!"
echo "============================================================================"
echo ""
echo -e "${GN}FreeSWITCH:${CL}     ${FS_PREFIX}"
echo -e "${GN}Bridge:${CL}         ${BRIDGE_DIR}"
echo -e "${GN}Config:${CL}         ${BRIDGE_DIR}/.env"
echo -e "${GN}3CX SIP:${CL}        ${FS_PREFIX}/etc/freeswitch/sip_profiles/external/3cx_gateway.xml"
echo -e "${GN}Setup Guide:${CL}    ${INSTALL_DIR}/3CX-SETUP.md"
echo ""
echo -e "${YW}NEXT STEPS:${CL}"
echo "  1. Edit ${BRIDGE_DIR}/.env (set GOOGLE_API_KEY, RIOS_SERVER_URL)"
echo "  2. Edit 3CX gateway XML (set extension credentials)"
echo "  3. Start: systemctl start freeswitch && systemctl start rios-bridge"
echo "  4. Verify: fs_cli -x 'sofia status gateway 3cx-rios'"
echo "  5. Call the RIOS extension from any phone!"
echo ""
