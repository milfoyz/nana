#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Mrkrab Stars style Telegram bot — one-file aiogram 3 script.

.env minimum:
BOT_TOKEN=123456: 8921053046:AAHa1i03Ji1tsAWHQSVMH2LB-9YhXArRGX0
ADMIN_IDS = 8207246901
SUBGRAM_API_KEY=...
BOTOHUB_TOKEN=...
PIARFLOW_API_KEY=...
HIVIEWS_API_KEY=...
DB_PATH=bot.db

Run:
python mrkrab_stars_bot.py
"""

import sys
import subprocess
import importlib

REQUIRED = {
    "aiogram": "aiogram>=3.20,<4",
    "aiohttp": "aiohttp>=3.9",
    "aiosqlite": "aiosqlite>=0.19",
    "dotenv": "python-dotenv>=1.0",
}

def _version_tuple(value: str) -> tuple[int, ...]:
    parts = []
    for chunk in value.split("."):
        digits = "".join(ch for ch in chunk if ch.isdigit())
        if digits:
            parts.append(int(digits))
        else:
            break
    return tuple(parts or [0])


for module_name, pip_name in REQUIRED.items():
    try:
        importlib.import_module(module_name)
        if module_name == "aiogram":
            from importlib.metadata import version
            if _version_tuple(version("aiogram")) < (3, 20):
                print(f"[upgrade] {pip_name}")
                subprocess.check_call([sys.executable, "-m", "pip", "install", "-U", pip_name])
    except ImportError:
        print(f"[install] {pip_name}")
        subprocess.check_call([sys.executable, "-m", "pip", "install", pip_name])

import os
import json
import html
import random
import string
import asyncio
import logging
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Optional, Callable, Awaitable

import aiohttp
import aiosqlite
from dotenv import load_dotenv
from aiogram import Bot, Dispatcher, F, Router, BaseMiddleware
from aiogram.filters import Command, CommandStart
from aiogram.types import (
    Message,
    CallbackQuery,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
    ReplyKeyboardMarkup,
    KeyboardButton,
)
from aiogram.utils.keyboard import InlineKeyboardBuilder
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import StatesGroup, State
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.exceptions import TelegramBadRequest, TelegramForbiddenError
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode

load_dotenv()

BOT_TOKEN = os.getenv("BOT_TOKEN", "").strip()
ADMIN_IDS_RAW = os.getenv("ADMIN_IDS", "")
ADMIN_IDS = {int(x.strip()) for x in ADMIN_IDS_RAW.split(",") if x.strip().isdigit()}
DB_PATH = os.getenv("DB_PATH", "bot.db")

# BOT_TOKEN нужен для первого запуска. Его также можно сохранить в БД через админку;
# новый bot_token будет применён после перезапуска процесса бота.

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
log = logging.getLogger("mrkrab-stars")

# Runtime performance caches. They are intentionally small and reset on restart.
_SETTINGS_CACHE: dict[str, str] = {}
_SETTINGS_CACHE_LOADED_AT = 0.0
_SETTINGS_CACHE_LOCK = asyncio.Lock()
_USER_CACHE: dict[int, tuple[float, dict[str, Any] | None]] = {}
_RENDER_TEXT_CACHE: dict[tuple[str, str], str] = {}
_HTTP_SESSION: aiohttp.ClientSession | None = None
_AD_LAST_CACHE: dict[int, float] = {}
_MAINTENANCE_LAST_RUN: dict[str, float] = {}
_UPSERT_LAST_CACHE: dict[int, float] = {}
_OP_GATE_CACHE: dict[tuple[int, str], float] = {}

router = Router()
admin_router = Router()

# Premium custom emoji IDs. Button labels are kept plain; icons are passed via
# icon_custom_emoji_id when the installed aiogram/Bot API supports it.
CUSTOM_EMOJI = {
    "settings": "5870982283724328568",
    "profile": "5870994129244131212",
    "people": "5870772616305839506",
    "user_ok": "5891207662678317861",
    "user_no": "5893192487324880883",
    "file": "5870528606328852614",
    "smile": "5870764288364252592",
    "growth": "5870930636742595124",
    "stats": "5870921681735781843",
    "home": "5873147866364514353",
    "lock": "6037249452824072506",
    "unlock": "6037496202990194718",
    "broadcast": "6039422865189638057",
    "check": "5870633910337015697",
    "cross": "5870657884844462243",
    "edit": "5870676941614354370",
    "trash": "5870875489362513438",
    "down": "5893057118545646106",
    "attach": "6039451237743595514",
    "link": "5769289093221454192",
    "info": "6028435952299413210",
    "bot": "6030400221232501136",
    "eye": "6037397706505195857",
    "hidden": "6037243349675544634",
    "send": "5963103826075456248",
    "download": "6039802767931871481",
    "bell": "6039486778597970865",
    "gift": "6032644646587338669",
    "clock": "5983150113483134607",
    "party": "6041731551845159060",
    "font": "5870801517140775623",
    "write": "5870753782874246579",
    "media": "6035128606563241721",
    "pin": "6042011682497106307",
    "wallet": "5769126056262898415",
    "box": "5884479287171485878",
    "cryptobot": "5260752406890711732",
    "calendar": "5890937706803894250",
    "tag": "5886285355279193209",
    "time_passed": "5775896410780079073",
    "apps": "5778672437122045013",
    "brush": "6050679691004612757",
    "add_text": "5771851822897566479",
    "format": "5778479949572738874",
    "money": "5904462880941545555",
    # Premium star emoji. Override with PREMIUM_STAR_EMOJI_ID if you have your own Telegram Stars emoji.
    "star": os.getenv("PREMIUM_STAR_EMOJI_ID", "5321485469249198987"),
    # Telegram standard gift icons for payout buttons. The values are supplied by the bot owner.
    "gift_heart": "5170145012310081615",
    "gift_bear": "5170233102089322756",
    "gift_present": "5170250947678437525",
    "gift_rose": "5168103777563050263",
    "gift_cake": "5170144170496491616",
    "gift_flowers": "5170314324215857265",
    "gift_rocket": "5170564780938756245",
    "gift_trophy": "5168043875654172773",
    "gift_ring": "5170690322832818290",
    "gift_diamond": "5170521118301225164",
    "send_money": "5890848474563352982",
    "accept_money": "5879814368572478751",
    "code": "5940433880585605708",
    "loading": "5345906554510012647",
    # Telegram example IDs from the prompt for subscription/check buttons.
    "subscribe": "6039450962865688331",
    "verify": "5774022692642492953",
}

BUTTON_ICON = {
    "admin_menu": "settings",
    "admin_stats": "stats",
    "admin_utm": "growth",
    "admin_broadcast": "broadcast",
    "admin_promos": "gift",
    "admin_create_link": "link",
    "admin_withdrawals": "wallet",
    "admin_settings": "settings",
    "admin_api": "apps",
    "admin_diagnostics": "info",
    "admin_users": "people",
    "earn": "send_money",
    "withdraw": "accept_money",
    "tasks": "check",
    "bonus": "gift",
    "profile": "profile",
    "buy_stars": "money",
    "slots": "gift",
    "dice": "apps",
    "basket": "party",
    "bowling": "box",
    "daily_bonus": "gift",
    "subscribe": "subscribe",
    "verify": "verify",
    "skip": "down",
    "back": "down",
    "home": "home",
    "edit": "edit",
    "default": "time_passed",
    "clear": "trash",
    "toggle": "loading",
    "cancel": "cross",
    "ok": "check",
    "no": "cross",
    "api": "apps",
    "economy": "money",
    "menu": "home",
    "texts": "write",
}

EMOJI_RE = re.compile(r"[\U0001F1E6-\U0001FAFF\u2600-\u27BF\uFE0F]+")
TG_EMOJI_RE = re.compile(r'<tg-emoji\s+emoji-id="\d+">(.*?)</tg-emoji>', re.DOTALL)
TAG_RE = re.compile(r"<[^>]+>")


def icon_id(name: str | None) -> str | None:
    if not name:
        return None
    return CUSTOM_EMOJI.get(name, name if str(name).isdigit() else None)


def ce(name: str, fallback: str) -> str:
    emoji_id = CUSTOM_EMOJI.get(name)
    if not emoji_id:
        return fallback
    return f'<tg-emoji emoji-id="{emoji_id}">{fallback}</tg-emoji>'


# Known emoji -> premium custom emoji converter for bot messages.
# Custom emoji that admins insert manually are preserved as <tg-emoji> tags.
KNOWN_PREMIUM_EMOJI = {
    "⚙️": "settings", "⚙": "settings",
    "👤": "profile",
    "👥": "people",
    "📁": "file",
    "🙂": "smile",
    "📊": "stats",
    "🏘": "home",
    "🔒": "lock",
    "🔓": "unlock",
    "📣": "broadcast",
    "✅": "check",
    "❌": "cross",
    "✖️": "cross", "✖": "cross",
    "🖋": "edit", "✏️": "edit", "✏": "edit",
    "🗑": "trash",
    "📰": "down",
    "📎": "attach",
    "🔗": "link",
    "ℹ️": "info", "ℹ": "info",
    "🤖": "bot",
    "👁": "eye",
    "⬆": "send", "⬆️": "send",
    "⬇": "download", "⬇️": "download",
    "🔔": "bell",
    "🎁": "gift",
    "⏰": "clock",
    "🎉": "party",
    "✍": "write",
    "🖼": "media",
    "📍": "pin",
    "👛": "wallet",
    "📦": "box",
    "👾": "cryptobot",
    "📅": "calendar",
    "🏷": "tag",
    "🕓": "time_passed",
    "🖌": "brush",
    "🔡": "add_text",
    "↔": "format", "↔️": "format",
    "🪙": "money",
    "⭐️": "star", "⭐": "star", "🌟": "star",
    "❤": "gift_heart", "❤️": "gift_heart",
    "🧸": "gift_bear",
    "🌹": "gift_rose",
    "🎂": "gift_cake",
    "💐": "gift_flowers",
    "🚀": "gift_rocket",
    "🏆": "gift_trophy",
    "💍": "gift_ring",
    "💎": "gift_diamond",
    "🔨": "code",
    "🔄": "loading",
}


def premiumize_known_emoji(text: str) -> str:
    """Replace known plain emoji with premium <tg-emoji> tags without touching existing custom emoji."""
    if not text:
        return text
    placeholders: list[str] = []

    def _hold(match: re.Match[str]) -> str:
        placeholders.append(match.group(0))
        return f"\u0000TGEMOJI{len(placeholders) - 1}\u0000"

    result = TG_EMOJI_RE.sub(_hold, str(text))
    for emoji, name in sorted(KNOWN_PREMIUM_EMOJI.items(), key=lambda x: len(x[0]), reverse=True):
        result = result.replace(emoji, ce(name, emoji))
    for i, value in enumerate(placeholders):
        result = result.replace(f"\u0000TGEMOJI{i}\u0000", value)
    return result


def should_render_html(kwargs: dict[str, Any] | None = None, parse_mode: ParseMode | str | None = ParseMode.HTML) -> bool:
    kwargs = kwargs or {}
    mode = kwargs.get("parse_mode", parse_mode)
    if mode is None:
        return False
    return str(mode).lower().endswith("html") or str(mode).lower() == "html"


def render_bot_text(text: str, *, parse_mode: ParseMode | str | None = ParseMode.HTML) -> str:
    """Prepare a stored/synthetic bot text for HTML parse mode with a tiny in-memory cache."""
    if not should_render_html({}, parse_mode):
        return text
    raw = str(text or "")
    cache_key = (raw, str(parse_mode))
    cached = _RENDER_TEXT_CACHE.get(cache_key)
    if cached is not None:
        return cached
    rendered = premiumize_known_emoji(raw)
    if len(raw) <= 4096:
        if len(_RENDER_TEXT_CACHE) > 512:
            _RENDER_TEXT_CACHE.clear()
        _RENDER_TEXT_CACHE[cache_key] = rendered
    return rendered


def strip_tg_emoji_tags(text: str) -> str:
    """Remove <tg-emoji> tags but keep their visible fallback emoji.

    Telegram can return ENTITY_TEXT_INVALID if a custom emoji id is no longer
    available, was mistyped, or is not accepted in the current context. The bot
    should never freeze because of decoration, so all send/edit helpers use this
    as the first fallback.
    """
    return TG_EMOJI_RE.sub(lambda m: m.group(1), str(text or ""))


def strip_html_for_plain_text(text: str) -> str:
    value = strip_tg_emoji_tags(text)
    value = TAG_RE.sub("", value)
    return html.unescape(value).strip() or "Сообщение"


def is_entity_text_invalid_error(error: Exception) -> bool:
    description = str(error).upper()
    return "ENTITY_TEXT_INVALID" in description or "CAN'T PARSE ENTITIES" in description or "CANT PARSE ENTITIES" in description


def is_message_not_modified_error(error: Exception) -> bool:
    return "MESSAGE IS NOT MODIFIED" in str(error).upper()


def safe_text_variants(text: str, parse_mode: ParseMode | str | None = ParseMode.HTML) -> list[tuple[str, ParseMode | str | None]]:
    """Return progressively safer text variants for Telegram send/edit calls."""
    raw = str(text or "")
    if not should_render_html({}, parse_mode):
        return [(raw, parse_mode), (strip_html_for_plain_text(raw), None)]
    rendered = render_bot_text(raw, parse_mode=parse_mode)
    no_custom = strip_tg_emoji_tags(rendered)
    plain = strip_html_for_plain_text(rendered)
    variants: list[tuple[str, ParseMode | str | None]] = [(rendered, parse_mode)]
    if no_custom != rendered:
        variants.append((no_custom, parse_mode))
    variants.append((plain, None))
    # Preserve order and remove exact duplicates.
    unique: list[tuple[str, ParseMode | str | None]] = []
    seen: set[tuple[str, str]] = set()
    for value, mode in variants:
        marker = (value, str(mode))
        if marker not in seen:
            unique.append((value, mode))
            seen.add(marker)
    return unique


def is_rich_text_setting(key: str) -> bool:
    meta = SETTINGS_META.get(key, {})
    return meta.get("kind") == "text" and meta.get("category") == "texts"


def message_rich_html(message: Message) -> str:
    """Return admin-sent text with Telegram formatting/entities converted to HTML.

    This lets admins edit bot texts by sending formatted Telegram messages — bold,
    underline, quote blocks, links and custom premium emoji are preserved without
    typing HTML tags manually.
    """
    value = getattr(message, "html_text", None) or getattr(message, "html_caption", None) or ""
    if value:
        return value
    text_value = message.text or message.caption or ""
    return html.escape(text_value)


def clean_button_text(text: str) -> str:
    text = TG_EMOJI_RE.sub(r"\1", str(text or ""))
    text = TAG_RE.sub("", text)
    text = EMOJI_RE.sub("", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text or "Кнопка"


def plain_text_for_draft(text: str) -> str:
    text = TG_EMOJI_RE.sub(r"\1", str(text or ""))
    text = TAG_RE.sub("", text)
    return html.unescape(text).strip()


def kbtn(text: str, icon: str | None = None) -> KeyboardButton:
    data = {"text": clean_button_text(text)}
    emoji_id = icon_id(icon)
    if emoji_id:
        data["icon_custom_emoji_id"] = emoji_id
    try:
        return KeyboardButton(**data)
    except Exception:
        return KeyboardButton(text=data["text"])


def ibtn(text: str, *, callback_data: str | None = None, url: str | None = None, icon: str | None = None, **extra: Any) -> InlineKeyboardButton:
    data: dict[str, Any] = {"text": clean_button_text(text)}
    if callback_data is not None:
        data["callback_data"] = callback_data
    if url is not None:
        data["url"] = url
    data.update(extra)
    emoji_id = icon_id(icon)
    if emoji_id:
        data["icon_custom_emoji_id"] = emoji_id
    try:
        return InlineKeyboardButton(**data)
    except Exception:
        data.pop("icon_custom_emoji_id", None)
        return InlineKeyboardButton(**data)


def strip_inline_keyboard_icons(markup: InlineKeyboardMarkup | None) -> InlineKeyboardMarkup | None:
    """Fallback keyboard without button premium icons if Telegram rejects an icon id."""
    if markup is None:
        return None
    try:
        rows: list[list[InlineKeyboardButton]] = []
        for row in markup.inline_keyboard:
            new_row: list[InlineKeyboardButton] = []
            for button in row:
                data = button.model_dump(exclude_none=True)
                data.pop("icon_custom_emoji_id", None)
                new_row.append(InlineKeyboardButton(**data))
            rows.append(new_row)
        return InlineKeyboardMarkup(inline_keyboard=rows)
    except Exception:
        return markup


def is_button_icon_error(error: Exception) -> bool:
    value = str(error).upper()
    return "BUTTON" in value and ("EMOJI" in value or "ICON" in value or "CUSTOM" in value)

DEFAULT_SETTINGS = {
    # System / API
    "bot_token": BOT_TOKEN,
    "admin_ids": ADMIN_IDS_RAW,
    "message_draft_animation_enabled": "0",
    "message_draft_animation_steps": "2",
    "performance_mode_enabled": "1",
    "settings_cache_ttl_seconds": "300",
    "user_cache_ttl_seconds": "2",
    "http_session_reuse_enabled": "1",
    "db_busy_timeout_ms": "5000",
    "maintenance_cleanup_interval_seconds": "600",
    "last_seen_update_interval_seconds": "45",
    "op_gate_cache_seconds": "5",
    "telegram_delete_pause_ms": "0",
    "start_sequence_enabled": "1",
    "start_ad_enabled": "1",
    "start_ad_provider": "botohub_views",
    "botohub_views_enabled": "1",
    "botohub_views_token": os.getenv("BOTOHUB_VIEWS_TOKEN", ""),
    "hiviews_enabled": "1",
    "hiwiews_enabled": "1",  # compatibility alias for the common misspelling in admin/search
    "hiviews_api_key": os.getenv("HIVIEWS_API_KEY", ""),
    "hiviews_start_delay_seconds": "2",
    "botohub_views_regular_enabled": "1",
    "botohub_views_regular_cooldown_minutes": "10",
    "botohub_views_regular_chance_percent": "35",
    "botohub_views_after_menu_enabled": "1",
    "botohub_views_after_task_enabled": "1",
    "botohub_views_after_bonus_enabled": "1",
    "botohub_views_after_game_enabled": "1",
    "botohub_views_after_withdraw_enabled": "1",
    "start_ad_before_op_enabled": "1",
    "start_ad_only_new_users": "1",
    "start_ad_button_text": "Забрать",
    "start_bonus_text": ce('party', '🎉') + ' <b>Поздравляю, ты выиграл мишку 🧸</b>\n\n' + ce('gift', '🎁') + ' <i>Забирай ежедневный бонус каждый день и копи звёзды быстрее.</i>\n\n<blockquote>Вывели уже более <b>800 000⭐</b> — можно начинать прямо сейчас.</blockquote>',
    "start_show_bonus_block": "1",
    "start_show_tasks_after_bonus": "1",
    "auto_next_task_after_completion": "1",
    "cleanup_bot_messages_enabled": "1",
    "cleanup_task_messages_enabled": "1",
    "cleanup_start_messages_enabled": "0",
    "cleanup_general_messages_enabled": "0",
    "cleanup_deleted_rows_after_days": "2",
    "subgram_api_key": os.getenv("SUBGRAM_API_KEY", ""),
    "subgram_enabled": "1",
    "subgram_get_links": "1",
    "subgram_max_sponsors": "5",
    "subgram_action": "subscribe",
    "bot_usage_requires_fresh_op": "1",
    "withdraw_requires_fresh_op": "1",
    "op_recheck_interval_minutes": "30",
    "withdraw_min_referrals": "0",
    "provider_role_subgram": "op",
    "botohub_token": os.getenv("BOTOHUB_TOKEN", ""),
    "botohub_enabled": "1",
    "provider_role_botohub": "tasks",
    "piarflow_api_key": os.getenv("PIARFLOW_API_KEY", ""),
    "piarflow_enabled": "1",
    "provider_role_piarflow": "tasks",
    "op_provider": "auto",  # auto | subgram | piarflow | botohub | mix
    "tasks_provider": "auto",  # auto | subgram | piarflow | botohub | mix
    # Economy
    "currency_name": "звёзды",
    "ref_reward": "4.5",
    "default_task_reward": "0.25",
    "default_task_reward_alt": "0.3",
    "default_subgram_task_reward": "0.25",
    "task_fixed_rewards_enabled": "1",
    "piarflow_max_sponsors": "5",
    "piarflow_check_include_chat_id": "0",
    "provider_logs_enabled": "1",
    "provider_logs_keep_days": "7",
    "daily_bonus_min": "0.01",
    "daily_bonus_max": "0.10",
    "game_default_bet": "1.0",
    "game_bet_presets": "0.1,0.25,0.5,1,2,5",
    "game_animation_enabled": "1",
    "game_animation_result_delay": "3",
    "game_message_cleanup_enabled": "1",
    "payout_channel_enabled": "0",
    "payout_channel_chat_id": os.getenv("PAYOUT_CHANNEL_CHAT_ID", ""),
    "payout_channel_title": "MrKrab Stars | Выплаты",
    "payout_channel_profile_button_enabled": "1",
    "payout_channel_notify_user": "1",
    "withdraw_amounts": "15,25,50,100",
    "withdraw_gifts_enabled": "1",
    # Texts from screenshots
    "start_text": ce('party', '🎉') + ' <b>Поздравляю, ты выиграл мишку 🧸</b>', 
    "earn_text": ce('send_money', '🪙') + ' <b>Партнёрская ссылка</b>\n\n<i>Приглашай друзей и получай <b>{ref_reward}⭐</b> за каждого, кто пройдёт обязательную подписку.</i>\n\n<blockquote>{ref_link}</blockquote>\n\n<b>Как набрать приглашения быстрее:</b>\n• отправь ссылку друзьям в личку;\n• закрепи её в своём канале;\n• оставь в комментариях и тематических чатах;\n• добавь в TikTok, Instagram, WhatsApp и другие соцсети.\n\n<b>Уже приглашено:</b> {invited}',
    "tasks_top_text": ce('gift', '🎁') + ' <b>Выполни все задания и получи 25⭐</b>\n\n<blockquote>Сначала выполни текущее задание — после проверки откроется следующее.</blockquote>',
    "task_text": ce('link', '🔗') + ' <b>Доступно задание №{num}</b>\n\n• <b>Подпишитесь на канал</b> → {link}\n• <b>Награда:</b> {reward}⭐',
    "task_not_done_text": ce('info', 'ℹ') + ' <b>Проверка пока не прошла</b>\n\n<i>Убедись, что подписка активна, затем нажми «Я выполнил» ещё раз.</i>',
    "withdraw_text": ce('wallet', '👛') + ' <b>Вывод звёзд</b>\n\n<b>На балансе:</b> {balance}⭐\n\n<blockquote>Выбери сумму, которую хочешь вывести. Заявка уйдёт на проверку администратору.</blockquote>',
    "withdraw_low_balance": ce('cross', '❌') + ' <b>Недостаточно звёзд</b>\n\nНужно: <b>{amount}⭐</b>\nНа балансе: <b>{balance}⭐</b>',
    "withdraw_created": ce('check', '✅') + ' <b>Заявка создана</b>\n\n<i>Сумма:</i> <b>{amount}⭐</b>\n<blockquote>Проверим заявку и обработаем вывод.</blockquote>',
    "bonus_text": '<i>Здесь можно забрать ежедневный бонус или испытать удачу в мини-играх.</i>\n\n<blockquote>Бонус доступен раз в 24 часа. В играх ставка списывается с баланса.</blockquote>',
    "bonus_received_text": ce('gift', '🎁') + ' <b>Бонус начислен</b>\n\nНа баланс добавлено: <b>{amount}⭐</b>\n\n<blockquote>Следующий бонус будет доступен через 24 часа.</blockquote>',
    "bonus_wait_text": ce('clock', '⏰') + ' <b>Бонус ещё не готов</b>\n\n<i>Возвращайся через {hours} ч. {minutes} мин.</i>',
    "buy_stars_text": ce('money', '🪙') + ' <b>Дешёвые звёзды</b>\n\n<i>Звёзды можно купить выгоднее, чем напрямую в Telegram.</i>\n\n<blockquote>@xackerstars2_bot\n@xackerstars2_bot\n@xackerstars2_bot</blockquote>',
    "profile_text": ce('profile', '👤') + ' <b>Профиль</b>\n\n<blockquote><b>ID:</b> <code>{user_id}</code>\n<b>Имя:</b> {first_name}\n<b>Username:</b> {username}</blockquote>\n\n<b>Баланс:</b> {balance}⭐\n<b>Приглашено:</b> {invited}\n<b>ОП пройдена:</b> {is_op_passed}\n\n<i>Дата регистрации: {created_at}</i>',
    "op_text": ce('lock', '🔒') + ' <b>Остался один шаг</b>\n\n<i>Подпишись на каналы ниже, чтобы открыть доступ к боту.</i>\n\n<blockquote>После подписки нажми «Я выполнил» — проверка займёт пару секунд.</blockquote>',
    # Main menu
    "profile_button_text": "Профиль",
    "buy_stars_button_text": "Дёшево Купить Звёзды",
    "buy_stars_button_enabled": "1",
    "admin_panel_button_text": "Админ-панель",
}

LEGACY_TEXT_DEFAULTS = {
    'start_text': 'Поздравляю, ты выиграл мишку 🧸\n\nЗабирай ежедневный бонус и зарабатывай звёзды!\n\nВывели уже более 800.000 звёзд!',
    'earn_text': 'Приглашай пользователей в бота\nи получай по {ref_reward}⭐ как только они подпишутся на каналы!\n\nВаша ссылка:\n{ref_link}\n\n❓ Как использовать реферальную ссылку?\n• Отправь её друзьям в личные сообщения 👥\n• Поделись ссылкой в своём Telegram-канале 🔗\n• Оставь её в комментариях или чатах 🗣\n• Распространяй ссылку в соцсетях: TikTok, Instagram, WhatsApp и других ↗️\n\n🗣 Вы пригласили: {invited}',
    'tasks_top_text': '👑 Выполни все задания и получи 25⭐!\n\n🔻 Выполни текущее задание, чтобы открыть новое',
    'task_text': '🎯 Доступно задание №{num}!\n\n• Подпишитесь на канал —>\n{link}\n• Награда: {reward} ⭐',
    'task_not_done_text': "Вы не выполнили задачу! Проверьте выполненные действия и нажмите на кнопку 'Я выполнил' еще раз",
    'withdraw_text': 'Заработано: {balance}⭐\n\n🔻 Выбери, подарок за сколько звёзд хочешь получить:',
    'withdraw_low_balance': 'Недостаточно звёзд для вывода. Нужно {amount}⭐, у вас {balance}⭐.',
    'withdraw_created': '✅ Заявка на вывод {amount}⭐ создана. Ожидайте проверки администратора.',
    'bonus_text': 'Здесь Вы можете 💰 забрать ежедневный бонус до 0.1⭐ или 🎰 испытать удачу в казино!',
    'bonus_received_text': '⭐ Бонус в размере {amount}⭐ начислен на ваш баланс в боте.\n\n• Повторно получить бонус можно через 24 часа',
    'bonus_wait_text': '⏳ Повторно получить бонус можно через {hours} ч. {minutes} мин.',
    'buy_stars_text': '⭐ Купить звёзды можно дешевле, чем в Telegram:\n\n@xackerstars2_bot\n@xackerstars2_bot\n@xackerstars2_bot',
    'op_text': 'Чтобы пользоваться ботом, подпишитесь на каналы ниже и нажмите «✅ Я выполнил». По скринам это обязательная подписка через SubGram.',
    "profile_text": ce("profile", "👤") + ' <b>Профиль</b>\n\nID: <code>{user_id}</code>\nИмя: {first_name}\nUsername: {username}\nБаланс: {balance}⭐\nПриглашено: {invited}\nОП пройдена: {is_op_passed}\nДата регистрации: {created_at}',
}

PREVIOUS_DESIGN_DEFAULTS = {
    'start_text': ce('gift', '🎁') + ' <b>Добро пожаловать!</b>\n\n<i>Забирай ежедневный бонус, выполняй задания и копи звёзды в удобном темпе.</i>\n\n<blockquote>Уже выведено более <b>800 000⭐</b>\nНачни с бонуса — дальше всё по шагам.</blockquote>',
    'tasks_top_text': ce('check', '✅') + ' <b>Задания</b>\n\n<i>Выполняй задания по очереди и забирай награду сразу после проверки.</i>\n\n<blockquote>Текущее задание открывает следующее.\nНе забудь нажать «Я выполнил» после подписки.</blockquote>',
    'task_text': ce('link', '🔗') + ' <b>Задание №{num}</b>\n\n<i>Перейди по ссылке и выполни действие.</i>\n\n<blockquote>{link}</blockquote>\n\n<b>Награда:</b> {reward}⭐',
}

VISUAL_TEXT_KEYS = tuple(dict.fromkeys((*LEGACY_TEXT_DEFAULTS.keys(), 'start_bonus_text')))
VISUAL_DESIGN_VERSION = "9"


async def apply_visual_design_migration(conn: aiosqlite.Connection) -> None:
    """Apply the v8 copywriting/design preset without overwriting admin-customized texts."""
    cur = await conn.execute("SELECT value FROM settings WHERE key='ui_design_version'")
    row = await cur.fetchone()
    if row and str(row["value"]) == VISUAL_DESIGN_VERSION:
        return

    for key in VISUAL_TEXT_KEYS:
        cur = await conn.execute("SELECT value FROM settings WHERE key=?", (key,))
        current_row = await cur.fetchone()
        current = current_row["value"] if current_row else ""
        legacy = LEGACY_TEXT_DEFAULTS.get(key, "")
        previous_design = PREVIOUS_DESIGN_DEFAULTS.get(key, "")
        if current in {"", legacy, previous_design}:
            await conn.execute(
                "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, str(DEFAULT_SETTINGS.get(key, ""))),
            )

    await conn.execute(
        "INSERT INTO settings(key,value) VALUES('ui_design_version',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (VISUAL_DESIGN_VERSION,),
    )



SETTINGS_CATEGORIES = {
    "api": {
        "title": "API, токены и доступ",
        "description": "Токены сервисов, обязательные подписки, провайдер заданий и список администраторов.",
        "keys": [
            "bot_token", "admin_ids",
            "subgram_enabled", "subgram_api_key", "provider_role_subgram", "subgram_get_links", "subgram_max_sponsors", "subgram_action",
            "bot_usage_requires_fresh_op", "withdraw_requires_fresh_op", "op_recheck_interval_minutes",
            "botohub_enabled", "botohub_token", "provider_role_botohub",
            "start_ad_provider", "botohub_views_enabled", "botohub_views_token", "hiviews_enabled", "hiviews_api_key", "hiviews_start_delay_seconds", "botohub_views_regular_enabled", "botohub_views_regular_cooldown_minutes", "botohub_views_regular_chance_percent",
            "piarflow_enabled", "piarflow_api_key", "provider_role_piarflow", "piarflow_max_sponsors", "piarflow_check_include_chat_id",
            "op_provider", "tasks_provider", "provider_logs_enabled", "provider_logs_keep_days",
        ],
    },
    "economy": {
        "title": "Экономика",
        "description": "Награды, бонусы, ставка игр и суммы вывода.",
        "keys": [
            "currency_name", "ref_reward", "task_fixed_rewards_enabled", "default_task_reward", "default_task_reward_alt", "default_subgram_task_reward",
            "daily_bonus_min", "daily_bonus_max", "game_default_bet", "game_bet_presets", "game_animation_enabled", "game_animation_result_delay", "game_message_cleanup_enabled", "payout_channel_enabled", "payout_channel_chat_id", "payout_channel_title", "payout_channel_profile_button_enabled", "payout_channel_notify_user", "withdraw_min_referrals", "withdraw_amounts", "withdraw_gifts_enabled",
        ],
    },
    "menu": {
        "title": "Главное меню",
        "description": "Кнопки в главном меню пользователя. Админ-кнопка видна только администраторам.",
        "keys": [
            "profile_button_text", "buy_stars_button_enabled", "buy_stars_button_text", "admin_panel_button_text",
            "start_sequence_enabled", "start_ad_enabled", "start_ad_provider", "botohub_views_enabled", "start_ad_before_op_enabled", "start_ad_only_new_users", "start_ad_button_text", "start_show_bonus_block", "start_show_tasks_after_bonus", "auto_next_task_after_completion",
            "botohub_views_after_menu_enabled", "botohub_views_after_task_enabled", "botohub_views_after_bonus_enabled", "botohub_views_after_game_enabled", "botohub_views_after_withdraw_enabled",
            "cleanup_bot_messages_enabled", "cleanup_task_messages_enabled", "cleanup_start_messages_enabled", "cleanup_general_messages_enabled", "cleanup_deleted_rows_after_days",
            "performance_mode_enabled", "settings_cache_ttl_seconds", "user_cache_ttl_seconds", "http_session_reuse_enabled", "db_busy_timeout_ms", "maintenance_cleanup_interval_seconds", "last_seen_update_interval_seconds", "op_gate_cache_seconds", "telegram_delete_pause_ms", "message_draft_animation_enabled", "message_draft_animation_steps",
        ],
    },
    "texts": {
        "title": "Тексты бота",
        "description": "Все пользовательские сообщения. Редактируйте обычным форматированным сообщением Telegram: жирный, подчёркивание, цитаты и premium emoji сохраняются автоматически.",
        "keys": [
            "start_text", "start_bonus_text", "earn_text", "tasks_top_text", "task_text", "task_not_done_text",
            "withdraw_text", "withdraw_low_balance", "withdraw_created",
            "bonus_text", "bonus_received_text", "bonus_wait_text", "buy_stars_text", "profile_text", "op_text",
        ],
    },
}


SETTINGS_META = {
    "bot_token": {
        "title": "Токен Telegram-бота",
        "category": "api",
        "kind": "secret",
        "desc": "Основной токен BotFather. Новый токен начнёт использоваться после перезапуска бота.",
        "placeholder": "123456:ABC-DEF...",
    },
    "admin_ids": {
        "title": "Администраторы",
        "category": "api",
        "kind": "csv_int",
        "desc": "Telegram ID администраторов через запятую. Текущие ID из .env остаются запасным доступом.",
        "placeholder": "123456789,987654321",
    },
    "performance_mode_enabled": {"title": "Быстрый режим", "category": "menu", "kind": "bool", "desc": "Отключает лишние тяжёлые операции по умолчанию и включает кэширование настроек для более быстрого ответа бота."},
    "settings_cache_ttl_seconds": {"title": "Кэш настроек, секунд", "category": "menu", "kind": "int", "desc": "Сколько секунд держать настройки в памяти, чтобы не обращаться к SQLite на каждую кнопку.", "placeholder": "300"},
    "user_cache_ttl_seconds": {"title": "Кэш пользователей, секунд", "category": "menu", "kind": "int", "desc": "Короткий кэш карточек пользователей и проверок бана. 0 — выключить.", "placeholder": "2"},
    "http_session_reuse_enabled": {"title": "Переиспользовать HTTP-сессию", "category": "menu", "kind": "bool", "desc": "Переиспользует одно aiohttp-подключение для внешних API, чтобы быстрее работать с SubGram, BotoHub и PiarFlow."},
    "db_busy_timeout_ms": {"title": "SQLite busy timeout, мс", "category": "menu", "kind": "int", "desc": "Сколько миллисекунд SQLite ждёт освобождения базы при одновременных действиях пользователей.", "placeholder": "5000"},
    "maintenance_cleanup_interval_seconds": {"title": "Пауза фоновой чистки, сек", "category": "menu", "kind": "int", "desc": "Как часто выполнять тяжёлую очистку старых логов. Чем больше значение, тем меньше нагрузка на SQLite при обычных действиях.", "placeholder": "600"},
    "last_seen_update_interval_seconds": {"title": "Обновлять last_seen, сек", "category": "menu", "kind": "int", "desc": "Минимальная пауза между обновлениями last_seen одного пользователя. Уменьшает число UPDATE на каждое сообщение.", "placeholder": "45"},
    "op_gate_cache_seconds": {"title": "Кэш свежей ОП, сек", "category": "menu", "kind": "int", "desc": "Короткий кэш результата проверки свежей ОП для ускорения частых кликов. 0 — выключить.", "placeholder": "5"},
    "telegram_delete_pause_ms": {"title": "Пауза удаления сообщений, мс", "category": "menu", "kind": "int", "desc": "Пауза между delete_message при очистке интерфейса. 0 быстрее, 20–50 мягче к лимитам Telegram.", "placeholder": "0"},
    "message_draft_animation_enabled": {
        "title": "Анимация черновика сообщений",
        "category": "menu",
        "kind": "bool",
        "desc": "Включает временный animated draft через sendMessageDraft перед финальной отправкой сообщения.",
    },
    "message_draft_animation_steps": {
        "title": "Шаги анимации черновика",
        "category": "menu",
        "kind": "int",
        "desc": "Сколько частичных обновлений черновика отправлять перед финальным сообщением. Рекомендуется 2–4.",
        "placeholder": "3",
    },
    "start_sequence_enabled": {"title": "Сценарий после /start", "category": "menu", "kind": "bool", "desc": "Включает красивую цепочку после старта: рекламный показ, бонусный блок, блок заданий и первое задание."},
    "start_ad_enabled": {"title": "Стартовая реклама", "category": "menu", "kind": "bool", "desc": "Включает стартовый рекламный показ через выбранный провайдер: HiViews или BotoHub Views."},
    "start_ad_provider": {
        "title": "Провайдер start-рекламы",
        "category": "api",
        "kind": "enum",
        "options": ["off", "botohub_views", "hiviews", "auto", "mix"],
        "desc": "Выбор провайдера для рекламного показа на /start: botohub_views — только BotoHub Views; hiviews — только HiViews; auto — HiViews с fallback на BotoHub Views; mix — случайный порядок с fallback; off — без start-рекламы.",
    },
    "botohub_views_enabled": {"title": "BotoHub Views включён", "category": "api", "kind": "bool", "desc": "Разрешить рекламные показы через views.botohub.me."},
    "botohub_views_token": {"title": "BotoHub Views token", "category": "api", "kind": "secret", "desc": "API token из @botohub_views_bot для рекламных показов Views. Это отдельный токен, не токен заданий BotoHub.", "placeholder": "Views API token"},
    "hiviews_enabled": {"title": "HiViews включён", "category": "api", "kind": "bool", "desc": "Включает интеграцию HiViews. Вызов выполняется только в личке и только на /start, как требует документация сервиса."},
    "hiwiews_enabled": {"title": "HiWiews включён (alias)", "category": "api", "kind": "bool", "desc": "Служебный alias для частой опечатки HiWiews. Основная настройка — hiviews_enabled."},
    "hiviews_api_key": {"title": "HiViews API key", "category": "api", "kind": "secret", "desc": "Персональный API key HiViews. Передаётся в HTTP Header Authorization при POST-запросе на https://hiviews.net/sendMessage.", "placeholder": "HiViews API key"},
    "hiviews_start_delay_seconds": {"title": "Пауза после HiViews /start", "category": "api", "kind": "float", "desc": "Сколько секунд ждать после успешной отправки HiViews перед продолжением стартового сценария. В примере интеграции указано 2 секунды.", "placeholder": "2"},
    "botohub_views_regular_enabled": {"title": "Views-показы вне /start", "category": "api", "kind": "bool", "desc": "Разрешает дополнительные рекламные показы BotoHub Views во время обычного использования бота."},
    "botohub_views_regular_cooldown_minutes": {"title": "Пауза между Views-показами", "category": "api", "kind": "int", "desc": "Минимальная пауза между дополнительными рекламными показами для одного пользователя, в минутах.", "placeholder": "10"},
    "botohub_views_regular_chance_percent": {"title": "Шанс Views-показа", "category": "api", "kind": "int", "desc": "Вероятность дополнительного показа при подходящем событии. 100 — показывать всегда, 0 — не показывать.", "placeholder": "35"},
    "start_ad_before_op_enabled": {"title": "Реклама перед ОП", "category": "menu", "kind": "bool", "desc": "Пробовать показать BotoHub Views самым первым сообщением сразу после /start, до проверки обязательной подписки."},
    "start_ad_only_new_users": {"title": "BotoHub Views только новым", "category": "menu", "kind": "bool", "desc": "Ограничивает стартовый показ BotoHub Views только новыми пользователями. Для HiViews это не применяется, чтобы не нарушать требование сервиса вызывать его первым действием на /start."},
    "start_ad_button_text": {"title": "Кнопка рекламы /start", "category": "menu", "kind": "text", "desc": "Оставлено для старого режима. В BotoHub Views кнопки и текст рекламного поста приходят от сервиса.", "placeholder": "Забрать"},
    "start_show_bonus_block": {"title": "Бонусный блок после /start", "category": "menu", "kind": "bool", "desc": "Показывать отдельное сообщение с напоминанием о ежедневном бонусе."},
    "start_show_tasks_after_bonus": {"title": "Задание после /start", "category": "menu", "kind": "bool", "desc": "После бонусного блока сразу показать блок заданий и выдать первое задание."},
    "auto_next_task_after_completion": {"title": "Следующее задание автоматически", "category": "menu", "kind": "bool", "desc": "После успешной проверки сразу выдавать следующее доступное задание без лишних действий пользователя."},
    "botohub_views_after_menu_enabled": {"title": "Views после разделов меню", "category": "menu", "kind": "bool", "desc": "Пробовать показывать рекламу после открытия разделов: рефералы, задания, вывод, профиль и т.п."},
    "botohub_views_after_task_enabled": {"title": "Views после заданий", "category": "menu", "kind": "bool", "desc": "Пробовать показывать рекламу после выдачи или успешного выполнения задания."},
    "botohub_views_after_bonus_enabled": {"title": "Views после бонуса", "category": "menu", "kind": "bool", "desc": "Пробовать показывать рекламу после получения ежедневного бонуса."},
    "botohub_views_after_game_enabled": {"title": "Views после игр", "category": "menu", "kind": "bool", "desc": "Пробовать показывать рекламу после результата мини-игры."},
    "botohub_views_after_withdraw_enabled": {"title": "Views после вывода", "category": "menu", "kind": "bool", "desc": "Пробовать показывать рекламу после создания заявки или открытия раздела вывода."},
    "cleanup_bot_messages_enabled": {"title": "Удаление старых сообщений", "category": "menu", "kind": "bool", "desc": "Включает систему запоминания и удаления старых сообщений бота, чтобы чат не засорялся."},
    "cleanup_task_messages_enabled": {"title": "Чистить задания", "category": "menu", "kind": "bool", "desc": "Перед следующим заданием удалять старую карточку задания, кнопки и служебные сообщения проверки."},
    "cleanup_start_messages_enabled": {"title": "Чистить стартовый сценарий", "category": "menu", "kind": "bool", "desc": "Перед новым /start удалять старые сообщения бота. По умолчанию выключено, чтобы сохранялся красивый стартовый порядок."},
    "cleanup_general_messages_enabled": {"title": "Чистить разделы меню", "category": "menu", "kind": "bool", "desc": "Перед открытием основных пользовательских разделов удалять предыдущие сообщения бота. Админ-панель не затрагивается."},
    "cleanup_deleted_rows_after_days": {"title": "Хранить журнал сообщений, дней", "category": "menu", "kind": "int", "desc": "Через сколько дней удалять старые записи о сообщениях из базы. На сами сообщения это не влияет.", "placeholder": "2"},
    "start_bonus_text": {"title": "Текст бонусного блока /start", "category": "texts", "kind": "text", "desc": "Сообщение, которое отправляется после рекламного показа. Можно редактировать обычным форматированным сообщением Telegram."},
    "subgram_api_key": {"title": "SubGram API key", "category": "api", "kind": "secret", "desc": "Ключ SubGram для обязательной подписки.", "placeholder": "API key"},
    "subgram_enabled": {"title": "SubGram включён", "category": "api", "kind": "bool", "desc": "Включает или отключает обязательную подписку через SubGram."},
    "subgram_get_links": {"title": "SubGram: выдавать ссылки", "category": "api", "kind": "bool", "desc": "Запрашивать ссылки спонсоров у SubGram."},
    "subgram_max_sponsors": {"title": "SubGram: максимум спонсоров", "category": "api", "kind": "int", "desc": "Сколько каналов максимум показывать пользователю.", "placeholder": "5"},
    "subgram_action": {
        "title": "SubGram: действие",
        "category": "api",
        "kind": "text",
        "desc": "Параметр action для SubGram. Обычно subscribe.",
        "placeholder": "subscribe",
    },
    "bot_usage_requires_fresh_op": {
        "title": "ОП при использовании бота",
        "category": "api",
        "kind": "bool",
        "desc": "Если включено, бот проверяет свежесть обязательной подписки перед любым пользовательским действием, кроме /start и кнопки проверки ОП.",
    },
    "withdraw_requires_fresh_op": {
        "title": "ОП перед выводом",
        "category": "api",
        "kind": "bool",
        "desc": "Если включено, пользователь сможет создать заявку на вывод только после свежей проверки обязательной подписки.",
    },
    "op_recheck_interval_minutes": {
        "title": "Повтор ОП, минут",
        "category": "api",
        "kind": "int",
        "desc": "Через сколько минут после последнего прохождения ОП нужно заново проверять подписку перед выводом.",
        "placeholder": "30",
    },
    "provider_role_subgram": {
        "title": "Роль SubGram",
        "category": "api",
        "kind": "enum",
        "options": ["off", "op", "tasks"],
        "desc": "Где использовать SubGram: off — отключить, op — обязательная подписка, tasks — задания.",
    },
    "botohub_token": {"title": "BotoHub token", "category": "api", "kind": "secret", "desc": "Токен BotoHub для заданий.", "placeholder": "Token"},
    "botohub_enabled": {"title": "BotoHub включён", "category": "api", "kind": "bool", "desc": "Разрешить работу BotoHub в назначенной роли."},
    "provider_role_botohub": {
        "title": "Роль BotoHub",
        "category": "api",
        "kind": "enum",
        "options": ["off", "op", "tasks"],
        "desc": "Где использовать BotoHub: off — отключить, op — обязательная подписка, tasks — задания.",
    },
    "piarflow_api_key": {"title": "PiarFlow API key", "category": "api", "kind": "secret", "desc": "Ключ PiarFlow для заданий.", "placeholder": "API key"},
    "piarflow_enabled": {"title": "PiarFlow включён", "category": "api", "kind": "bool", "desc": "Разрешить работу PiarFlow в назначенной роли."},
    "provider_role_piarflow": {
        "title": "Роль PiarFlow",
        "category": "api",
        "kind": "enum",
        "options": ["off", "op", "tasks"],
        "desc": "Где использовать PiarFlow: off — отключить, op — обязательная подписка, tasks — задания.",
    },
    "piarflow_max_sponsors": {"title": "PiarFlow: максимум спонсоров", "category": "api", "kind": "int", "desc": "Сколько спонсоров запрашивать у PiarFlow за один запрос. Если раньше показывался один спонсор — проверьте это значение.", "placeholder": "5"},
    "piarflow_check_include_chat_id": {"title": "PiarFlow: chat_id при проверке", "category": "api", "kind": "bool", "desc": "Добавлять chat_id в запрос /sponsors/check. По документации PiarFlow для проверки нужны только user_id и links, поэтому по умолчанию выключено."},
    "provider_logs_enabled": {"title": "Подробные логи провайдеров", "category": "api", "kind": "bool", "desc": "Сохранять понятные логи запросов и ответов SubGram, PiarFlow, BotoHub и BotoHub Views для диагностики."},
    "provider_logs_keep_days": {"title": "Хранить логи провайдеров, дней", "category": "api", "kind": "int", "desc": "Через сколько дней очищать подробные логи провайдеров.", "placeholder": "7"},
    "op_provider": {
        "title": "Провайдер ОП",
        "category": "api",
        "kind": "enum",
        "options": ["auto", "subgram", "piarflow", "botohub", "mix"],
        "desc": "Какой провайдер обслуживает обязательную подписку. auto берёт первого доступного с ролью op, mix выбирает случайно.",
    },
    "tasks_provider": {
        "title": "Провайдер заданий",
        "category": "api",
        "kind": "enum",
        "options": ["auto", "subgram", "piarflow", "botohub", "mix"],
        "desc": "Откуда брать задания. Используются только провайдеры с ролью tasks. auto берёт первого доступного, mix выбирает случайно.",
    },
    "currency_name": {"title": "Название валюты", "category": "economy", "kind": "text", "desc": "Название внутренней валюты в интерфейсе.", "placeholder": "звёзды"},
    "ref_reward": {"title": "Награда за реферала", "category": "economy", "kind": "float", "desc": "Сколько начислять пригласившему после прохождения ОП.", "placeholder": "4.5"},
    "task_fixed_rewards_enabled": {"title": "Фиксированные награды заданий", "category": "economy", "kind": "bool", "desc": "Если включено, награды за задания всегда берутся из настроек админки, а цены из API провайдеров игнорируются."},
    "default_task_reward": {"title": "Фикс. награда PiarFlow", "category": "economy", "kind": "float", "desc": "Фиксированная награда за задание PiarFlow. Используется при включённых фиксированных наградах.", "placeholder": "0.25"},
    "default_task_reward_alt": {"title": "Фикс. награда BotoHub", "category": "economy", "kind": "float", "desc": "Фиксированная награда за задание BotoHub.", "placeholder": "0.3"},
    "default_subgram_task_reward": {"title": "Фикс. награда SubGram", "category": "economy", "kind": "float", "desc": "Фиксированная награда за задание SubGram, когда SubGram используется в режиме заданий.", "placeholder": "0.25"},
    "daily_bonus_min": {"title": "Минимальный ежедневный бонус", "category": "economy", "kind": "float", "desc": "Нижняя граница случайного бонуса.", "placeholder": "0.01"},
    "daily_bonus_max": {"title": "Максимальный ежедневный бонус", "category": "economy", "kind": "float", "desc": "Верхняя граница случайного бонуса.", "placeholder": "0.10"},
    "game_default_bet": {"title": "Ставка в играх", "category": "economy", "kind": "float", "desc": "Ставка по умолчанию, если пользователь ещё не выбрал свою.", "placeholder": "1.0"},
    "game_bet_presets": {"title": "Быстрые ставки", "category": "economy", "kind": "csv_float", "desc": "Кнопки выбора ставки в играх через запятую.", "placeholder": "0.1,0.25,0.5,1,2,5"},
    "game_animation_enabled": {"title": "Анимация игр", "category": "economy", "kind": "bool", "desc": "Использовать настоящие Telegram-анимации dice: 🎲, 🎰, 🏀, 🎳. Результат считается по выпавшему значению Telegram."},
    "game_animation_result_delay": {"title": "Задержка результата игры", "category": "economy", "kind": "int", "desc": "Сколько секунд ждать после отправки анимации перед сообщением результата.", "placeholder": "3"},
    "game_message_cleanup_enabled": {"title": "Чистить сообщения игр", "category": "economy", "kind": "bool", "desc": "Перед новым броском удалять предыдущую анимацию и результат игры, чтобы экран оставался чистым."},
    "payout_channel_enabled": {"title": "Канал выплат включён", "category": "economy", "kind": "bool", "desc": "Отправлять новые заявки на вывод в отдельный канал выплат с кнопками для администраторов."},
    "payout_channel_chat_id": {"title": "Канал выплат", "category": "economy", "kind": "text", "desc": "ID или username канала выплат. Бот должен быть администратором канала. Пример: -1001234567890 или @my_payouts_channel.", "placeholder": "-1001234567890 или @channel"},
    "payout_channel_title": {"title": "Заголовок канала выплат", "category": "economy", "kind": "text", "desc": "Первая строка в публичной карточке заявки на вывод.", "placeholder": "MrKrab Stars | Выплаты"},
    "payout_channel_profile_button_enabled": {"title": "Кнопка профиля в выплатах", "category": "economy", "kind": "bool", "desc": "Показывать в сообщении канала кнопку «Профиль». Нажимать её могут только администраторы бота."},
    "payout_channel_notify_user": {"title": "Уведомлять пользователя о выплате", "category": "economy", "kind": "bool", "desc": "Отправлять пользователю сообщение, когда админ отправил или отклонил заявку."},
    "withdraw_min_referrals": {"title": "Мин. рефералов для вывода", "category": "economy", "kind": "int", "desc": "Сколько приглашённых пользователей должен иметь человек, чтобы создать заявку на вывод. Засчитываются рефералы, которые прошли ОП и дали реферальную награду. 0 — без ограничения.", "placeholder": "0"},
    "withdraw_amounts": {"title": "Суммы вывода", "category": "economy", "kind": "csv_float", "desc": "Кнопки вывода через запятую. Используется, когда выключен режим стандартных подарков.", "placeholder": "15,25,50,100"},
    "withdraw_gifts_enabled": {"title": "Стандартные подарки в выводе", "category": "economy", "kind": "bool", "desc": "Показывать в меню вывода все стандартные подарки Telegram с их premium-иконками: сердце, мишка, подарок, роза, тортик, цветы, ракета, кубок, кольцо и алмаз."},
    "start_text": {"title": "Стартовый текст", "category": "texts", "kind": "text", "desc": "Сообщение после /start и прохождения ОП."},
    "earn_text": {"title": "Текст реферального раздела", "category": "texts", "kind": "text", "desc": "Доступные переменные: {ref_reward}, {ref_link}, {invited}."},
    "tasks_top_text": {"title": "Верхний текст заданий", "category": "texts", "kind": "text", "desc": "Показывается перед выдачей задания."},
    "task_text": {"title": "Текст одного задания", "category": "texts", "kind": "text", "desc": "Доступные переменные: {num}, {link}, {reward}."},
    "task_not_done_text": {"title": "Текст невыполненного задания", "category": "texts", "kind": "text", "desc": "Показывается, если проверка задания не прошла."},
    "withdraw_text": {"title": "Текст вывода", "category": "texts", "kind": "text", "desc": "Доступная переменная: {balance}."},
    "withdraw_low_balance": {"title": "Недостаточно для вывода", "category": "texts", "kind": "text", "desc": "Доступные переменные: {amount}, {balance}."},
    "withdraw_created": {"title": "Заявка на вывод создана", "category": "texts", "kind": "text", "desc": "Доступная переменная: {amount}."},
    "bonus_text": {"title": "Текст бонусов и игр", "category": "texts", "kind": "text", "desc": "Описание раздела бонусов."},
    "bonus_received_text": {"title": "Бонус начислен", "category": "texts", "kind": "text", "desc": "Доступная переменная: {amount}."},
    "bonus_wait_text": {"title": "Бонус ещё недоступен", "category": "texts", "kind": "text", "desc": "Доступные переменные: {hours}, {minutes}."},
    "buy_stars_text": {"title": "Текст покупки звёзд", "category": "texts", "kind": "text", "desc": "Сообщение по кнопке покупки звёзд."},
    "profile_text": {"title": "Текст профиля", "category": "texts", "kind": "text", "desc": "Доступные переменные: {user_id}, {first_name}, {username}, {balance}, {invited}, {is_op_passed}, {created_at}, {currency_name}."},
    "op_text": {"title": "Текст обязательной подписки", "category": "texts", "kind": "text", "desc": "Показывается вместе с кнопками каналов SubGram."},
    "profile_button_text": {"title": "Кнопка профиля", "category": "menu", "kind": "text", "desc": "Название кнопки профиля в главном меню.", "placeholder": "Профиль"},
    "buy_stars_button_text": {"title": "Кнопка дешёвых звёзд", "category": "menu", "kind": "text", "desc": "Название кнопки покупки дешёвых звёзд в главном меню.", "placeholder": "Дёшево Купить Звёзды"},
    "buy_stars_button_enabled": {"title": "Показывать дешёвые звёзды", "category": "menu", "kind": "bool", "desc": "Если выключено, кнопка покупки звёзд скрывается из главного меню."},
    "admin_panel_button_text": {"title": "Кнопка админ-панели", "category": "menu", "kind": "text", "desc": "Название кнопки админ-панели. Показывается только администраторам.", "placeholder": "Админ-панель"},
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def parse_dt(value: str | None) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except Exception:
        return None


def fmt_amount(x: float) -> str:
    s = f"{x:.2f}".rstrip("0").rstrip(".")
    return s if s else "0"


def star_emoji() -> str:
    return ce("star", "⭐")


def star_amount(value: float | int | str) -> str:
    try:
        amount = fmt_amount(float(value))
    except Exception:
        amount = html.escape(str(value))
    return f"{amount}{star_emoji()}"


STANDARD_PAYOUT_GIFTS = [
    {"amount": 15.0, "name": "Сердце", "gift_id": "5170145012310081615", "emoji": "❤️", "icon": "gift_heart"},
    {"amount": 15.0, "name": "Мишка", "gift_id": "5170233102089322756", "emoji": "🧸", "icon": "gift_bear"},
    {"amount": 25.0, "name": "Подарок", "gift_id": "5170250947678437525", "emoji": "🎁", "icon": "gift_present"},
    {"amount": 25.0, "name": "Роза", "gift_id": "5168103777563050263", "emoji": "🌹", "icon": "gift_rose"},
    {"amount": 50.0, "name": "Тортик", "gift_id": "5170144170496491616", "emoji": "🎂", "icon": "gift_cake"},
    {"amount": 50.0, "name": "Цветы", "gift_id": "5170314324215857265", "emoji": "💐", "icon": "gift_flowers"},
    {"amount": 50.0, "name": "Ракета", "gift_id": "5170564780938756245", "emoji": "🚀", "icon": "gift_rocket"},
    {"amount": 100.0, "name": "Кубок", "gift_id": "5168043875654172773", "emoji": "🏆", "icon": "gift_trophy"},
    {"amount": 100.0, "name": "Кольцо", "gift_id": "5170690322832818290", "emoji": "💍", "icon": "gift_ring"},
    {"amount": 100.0, "name": "Алмаз", "gift_id": "5170521118301225164", "emoji": "💎", "icon": "gift_diamond"},
]


def custom_emoji_tag(emoji_id: str | None, fallback: str) -> str:
    emoji_id = str(emoji_id or "").strip()
    if not emoji_id:
        return fallback
    return f'<tg-emoji emoji-id="{html.escape(emoji_id)}">{html.escape(fallback)}</tg-emoji>'


def payout_gift_by_id(gift_id: str | None) -> dict[str, Any] | None:
    gift_id = str(gift_id or "").strip()
    for gift in STANDARD_PAYOUT_GIFTS:
        if str(gift["gift_id"]) == gift_id:
            return gift
    return None


def payout_gift_by_amount(amount: float | int | str) -> dict[str, Any]:
    try:
        value = float(amount)
    except Exception:
        value = 0.0
    for gift in STANDARD_PAYOUT_GIFTS:
        if abs(float(gift["amount"]) - value) < 1e-9:
            return gift
    if value >= 100:
        return payout_gift_by_id("5170690322832818290") or STANDARD_PAYOUT_GIFTS[-1]
    if value >= 50:
        return payout_gift_by_id("5170144170496491616") or STANDARD_PAYOUT_GIFTS[4]
    if value >= 25:
        return payout_gift_by_id("5170250947678437525") or STANDARD_PAYOUT_GIFTS[2]
    return payout_gift_by_id("5170233102089322756") or STANDARD_PAYOUT_GIFTS[1]


def payout_gift_icon(gift: dict[str, Any] | None) -> str:
    if not gift:
        return ce("gift", "🎁")
    return custom_emoji_tag(str(gift.get("gift_id") or ""), str(gift.get("emoji") or "🎁"))


def payout_gift_label(gift: dict[str, Any] | None, *, include_id: bool = False) -> str:
    if not gift:
        return ce("gift", "🎁")
    base = f"{payout_gift_icon(gift)} {html.escape(str(gift.get('name') or 'Подарок'))}"
    if include_id:
        base += f" <code>{html.escape(str(gift.get('gift_id') or ''))}</code>"
    return base


class DBContext:
    """Safe async context wrapper for aiosqlite.

    Важно для Termux/Python 3.13: нельзя делать `async with await aiosqlite.connect(...)`,
    потому что подключение уже await-нуто, а `async with` пытается стартовать внутренний
    поток aiosqlite второй раз и падает с `threads can only be started once`.
    Этот wrapper возвращает уже открытое соединение в `__aenter__` без повторного await.
    """

    def __init__(self, conn: aiosqlite.Connection):
        self.conn = conn

    async def __aenter__(self) -> aiosqlite.Connection:
        return self.conn

    async def __aexit__(self, exc_type, exc, tb) -> None:
        await self.conn.close()


async def db() -> DBContext:
    conn = await aiosqlite.connect(DB_PATH, timeout=30)
    conn.row_factory = aiosqlite.Row
    return DBContext(conn)


async def init_db() -> None:
    async with await db() as conn:
        try:
            await conn.execute("PRAGMA journal_mode=WAL")
            await conn.execute("PRAGMA synchronous=NORMAL")
            await conn.execute("PRAGMA temp_store=MEMORY")
            await conn.execute("PRAGMA busy_timeout=5000")
        except Exception as e:
            log.debug("SQLite pragma setup skipped: %s", e)
        await conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY,
                username TEXT,
                first_name TEXT,
                referrer_id INTEGER,
                source_code TEXT,
                is_op_passed INTEGER DEFAULT 0,
                op_passed_at TEXT,
                ref_rewarded INTEGER DEFAULT 0,
                balance REAL DEFAULT 0,
                invited_count INTEGER DEFAULT 0,
                is_banned INTEGER DEFAULT 0,
                created_at TEXT,
                last_seen TEXT
            );
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            CREATE TABLE IF NOT EXISTS utm_links (
                code TEXT PRIMARY KEY,
                title TEXT,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS utm_deleted_links (
                code TEXT PRIMARY KEY,
                deleted_by INTEGER,
                deleted_at TEXT
            );
            CREATE TABLE IF NOT EXISTS op_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                source_code TEXT,
                service TEXT,
                status TEXT,
                response_json TEXT,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS op_sessions (
                user_id INTEGER PRIMARY KEY,
                provider TEXT,
                links_json TEXT,
                response_json TEXT,
                status TEXT,
                updated_at TEXT
            );
            CREATE TABLE IF NOT EXISTS task_sessions (
                user_id INTEGER PRIMARY KEY,
                service TEXT,
                link TEXT,
                reward REAL,
                task_num INTEGER DEFAULT 1,
                status TEXT,
                updated_at TEXT
            );
            CREATE TABLE IF NOT EXISTS task_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                service TEXT,
                link TEXT,
                reward REAL,
                status TEXT,
                response_json TEXT,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS promocodes (
                code TEXT PRIMARY KEY,
                amount REAL,
                max_activations INTEGER,
                activations INTEGER DEFAULT 0,
                is_active INTEGER DEFAULT 1,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS promo_activations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                code TEXT,
                user_id INTEGER,
                created_at TEXT,
                UNIQUE(code, user_id)
            );
            CREATE TABLE IF NOT EXISTS reward_checks (
                code TEXT PRIMARY KEY,
                amount REAL NOT NULL,
                max_activations INTEGER NOT NULL,
                activations INTEGER DEFAULT 0,
                is_active INTEGER DEFAULT 1,
                created_by INTEGER,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS reward_check_activations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                code TEXT,
                user_id INTEGER,
                amount REAL,
                created_at TEXT,
                UNIQUE(code, user_id)
            );
            CREATE TABLE IF NOT EXISTS pending_reward_checks (
                user_id INTEGER PRIMARY KEY,
                code TEXT,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS withdraw_requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                amount REAL,
                status TEXT DEFAULT 'pending',
                created_at TEXT,
                updated_at TEXT
            );
            CREATE TABLE IF NOT EXISTS bonus_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                amount REAL,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS game_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                game TEXT,
                bet REAL,
                win REAL,
                result TEXT,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS game_bets (
                user_id INTEGER PRIMARY KEY,
                bet REAL,
                updated_at TEXT
            );
            CREATE TABLE IF NOT EXISTS admin_action_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                admin_id INTEGER,
                user_id INTEGER,
                action TEXT,
                details TEXT,
                created_at TEXT
            );
            CREATE TABLE IF NOT EXISTS bot_message_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                chat_id INTEGER,
                message_id INTEGER,
                scope TEXT,
                created_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_bot_message_logs_user_scope ON bot_message_logs(user_id, scope, id);
            CREATE INDEX IF NOT EXISTS idx_bot_message_logs_chat ON bot_message_logs(chat_id, message_id);
            CREATE TABLE IF NOT EXISTS ad_impression_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                chat_id INTEGER,
                placement TEXT,
                result_code INTEGER,
                response_json TEXT,
                created_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_ad_impression_logs_user ON ad_impression_logs(user_id, id);
            CREATE TABLE IF NOT EXISTS provider_event_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                provider TEXT,
                event TEXT,
                user_id INTEGER,
                chat_id INTEGER,
                status TEXT,
                http_status INTEGER,
                duration_ms INTEGER,
                request_json TEXT,
                response_json TEXT,
                error TEXT,
                created_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_provider_event_logs_provider ON provider_event_logs(provider, id);
            CREATE INDEX IF NOT EXISTS idx_provider_event_logs_user ON provider_event_logs(user_id, id);
            CREATE INDEX IF NOT EXISTS idx_provider_event_logs_created ON provider_event_logs(created_at);
            CREATE INDEX IF NOT EXISTS idx_ad_impression_logs_placement ON ad_impression_logs(user_id, placement, id);
            CREATE INDEX IF NOT EXISTS idx_ad_impression_logs_created ON ad_impression_logs(created_at);
            CREATE INDEX IF NOT EXISTS idx_bot_message_logs_created ON bot_message_logs(created_at);
            CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
            CREATE INDEX IF NOT EXISTS idx_users_source ON users(source_code);
            CREATE INDEX IF NOT EXISTS idx_utm_deleted_links_code ON utm_deleted_links(code);
            CREATE INDEX IF NOT EXISTS idx_users_referrer ON users(referrer_id);
            CREATE INDEX IF NOT EXISTS idx_users_last_seen ON users(last_seen);
            CREATE INDEX IF NOT EXISTS idx_users_banned ON users(is_banned);
            CREATE INDEX IF NOT EXISTS idx_task_logs_user ON task_logs(user_id, id);
            CREATE INDEX IF NOT EXISTS idx_task_logs_status ON task_logs(status, created_at);
            CREATE INDEX IF NOT EXISTS idx_withdraw_status ON withdraw_requests(status, created_at);
            CREATE INDEX IF NOT EXISTS idx_withdraw_user ON withdraw_requests(user_id, id);
            CREATE INDEX IF NOT EXISTS idx_bonus_logs_user ON bonus_logs(user_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_game_logs_user ON game_logs(user_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_reward_check_activations_user ON reward_check_activations(user_id, id);
            CREATE INDEX IF NOT EXISTS idx_reward_check_activations_code ON reward_check_activations(code, id);
            CREATE INDEX IF NOT EXISTS idx_reward_checks_active ON reward_checks(is_active, created_at);
            CREATE INDEX IF NOT EXISTS idx_pending_reward_checks_code ON pending_reward_checks(code, created_at);
            CREATE INDEX IF NOT EXISTS idx_op_logs_user ON op_logs(user_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_op_sessions_provider ON op_sessions(provider, updated_at);
            """
        )
        # Миграции для существующих баз: дополнительные поля заявок на вывод.
        for sql in (
            "ALTER TABLE withdraw_requests ADD COLUMN payout_channel_chat_id TEXT",
            "ALTER TABLE withdraw_requests ADD COLUMN payout_channel_message_id INTEGER",
            "ALTER TABLE withdraw_requests ADD COLUMN processed_by INTEGER",
            "ALTER TABLE withdraw_requests ADD COLUMN processed_note TEXT",
            "ALTER TABLE withdraw_requests ADD COLUMN gift_id TEXT",
            "ALTER TABLE withdraw_requests ADD COLUMN gift_name TEXT",
        ):
            try:
                await conn.execute(sql)
            except Exception:
                pass
        for k, v in DEFAULT_SETTINGS.items():
            await conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)", (k, str(v)))
        cur = await conn.execute("SELECT value FROM settings WHERE key='piarflow_check_fix_version'")
        fix_row = await cur.fetchone()
        if not fix_row or str(fix_row["value"]) != "22":
            await conn.execute("INSERT INTO settings(key,value) VALUES('piarflow_check_include_chat_id','0') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            await conn.execute("INSERT INTO settings(key,value) VALUES('piarflow_check_fix_version','22') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        cur = await conn.execute("SELECT value FROM settings WHERE key='optimization_version'")
        opt_row = await cur.fetchone()
        if not opt_row or str(opt_row["value"]) != "27":
            # HiViews example used 2 seconds; for bot responsiveness keep only a short pause unless admin changed it manually.
            cur_delay = await conn.execute("SELECT value FROM settings WHERE key='hiviews_start_delay_seconds'")
            delay_row = await cur_delay.fetchone()
            if delay_row and str(delay_row["value"]).strip() in {"2", "2.0"}:
                await conn.execute("UPDATE settings SET value='0.3' WHERE key='hiviews_start_delay_seconds'")
            await conn.execute("INSERT INTO settings(key,value) VALUES('optimization_version','27') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        await apply_visual_design_migration(conn)
        await conn.commit()
    await load_settings_cache(force=True)


async def load_settings_cache(force: bool = False) -> None:
    """Load settings once and refresh them occasionally instead of hitting SQLite on every button."""
    global _SETTINGS_CACHE_LOADED_AT
    now_mono = time.monotonic()
    if not force and _SETTINGS_CACHE:
        try:
            ttl = int(_SETTINGS_CACHE.get("settings_cache_ttl_seconds", "300") or 300)
        except Exception:
            ttl = 300
        if ttl > 0 and now_mono - _SETTINGS_CACHE_LOADED_AT < ttl:
            return
    async with _SETTINGS_CACHE_LOCK:
        now_mono = time.monotonic()
        if not force and _SETTINGS_CACHE:
            try:
                ttl = int(_SETTINGS_CACHE.get("settings_cache_ttl_seconds", "300") or 300)
            except Exception:
                ttl = 300
            if ttl > 0 and now_mono - _SETTINGS_CACHE_LOADED_AT < ttl:
                return
        async with await db() as conn:
            cur = await conn.execute("SELECT key, value FROM settings")
            rows = await cur.fetchall()
        _SETTINGS_CACHE.clear()
        _SETTINGS_CACHE.update({str(row["key"]): str(row["value"]) for row in rows})
        _SETTINGS_CACHE_LOADED_AT = time.monotonic()


async def get_setting(key: str, default: str = "") -> str:
    if not _SETTINGS_CACHE:
        await load_settings_cache(force=True)
    else:
        await load_settings_cache(force=False)
    return _SETTINGS_CACHE.get(key, default)


async def set_setting(key: str, value: str) -> None:
    async with await db() as conn:
        await conn.execute("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))
        await conn.commit()
    _SETTINGS_CACHE[key] = str(value)
    if key in {"admin_ids", "user_cache_ttl_seconds", "last_seen_update_interval_seconds"}:
        _USER_CACHE.clear()
        _UPSERT_LAST_CACHE.clear()
    if key in {"bot_usage_requires_fresh_op", "withdraw_requires_fresh_op", "op_recheck_interval_minutes", "op_gate_cache_seconds"}:
        _invalidate_op_gate_cache()
    if setting_meta(key).get("category") == "texts":
        _RENDER_TEXT_CACHE.clear()


async def get_float_setting(key: str, default: float) -> float:
    try:
        return float(await get_setting(key, str(default)))
    except Exception:
        return default

async def get_int_setting(key: str, default: int) -> int:
    try:
        return int(await get_setting(key, str(default)))
    except Exception:
        return default


def _maintenance_due(name: str, interval_seconds: int = 600) -> bool:
    """Return True only occasionally so routine inserts do not run heavy DELETE queries every time."""
    interval = max(30, int(interval_seconds or 600))
    now_mono = time.monotonic()
    last = _MAINTENANCE_LAST_RUN.get(name, 0.0)
    if now_mono - last < interval:
        return False
    _MAINTENANCE_LAST_RUN[name] = now_mono
    return True


def _cache_gate_key(user_id: int, scope: str) -> tuple[int, str]:
    return (int(user_id), str(scope))


def _op_gate_cache_ok(user_id: int, scope: str) -> bool:
    until = _OP_GATE_CACHE.get(_cache_gate_key(user_id, scope), 0.0)
    return bool(until and time.monotonic() < until)


async def _remember_op_gate_ok(user_id: int, scope: str) -> None:
    ttl = max(0, await get_int_setting("op_gate_cache_seconds", 5))
    if ttl > 0:
        _OP_GATE_CACHE[_cache_gate_key(user_id, scope)] = time.monotonic() + min(ttl, 30)


def _invalidate_op_gate_cache(user_id: int | None = None) -> None:
    if user_id is None:
        _OP_GATE_CACHE.clear()
        return
    uid = int(user_id)
    for key in list(_OP_GATE_CACHE.keys()):
        if key[0] == uid:
            _OP_GATE_CACHE.pop(key, None)


class ReusableHTTPSessionContext:
    def __init__(self) -> None:
        self._local_session: aiohttp.ClientSession | None = None

    async def __aenter__(self) -> aiohttp.ClientSession:
        global _HTTP_SESSION
        if await get_setting("http_session_reuse_enabled", "1") == "1":
            if _HTTP_SESSION is None or _HTTP_SESSION.closed:
                connector = aiohttp.TCPConnector(limit=100, ttl_dns_cache=300, enable_cleanup_closed=True)
                timeout = aiohttp.ClientTimeout(total=20)
                _HTTP_SESSION = aiohttp.ClientSession(connector=connector, timeout=timeout)
            return _HTTP_SESSION
        self._local_session = aiohttp.ClientSession()
        return self._local_session

    async def __aexit__(self, exc_type, exc, tb) -> None:
        if self._local_session is not None:
            await self._local_session.close()


async def http_session_context() -> ReusableHTTPSessionContext:
    return ReusableHTTPSessionContext()


async def close_runtime_resources() -> None:
    global _HTTP_SESSION
    if _HTTP_SESSION is not None and not _HTTP_SESSION.closed:
        await _HTTP_SESSION.close()
    _HTTP_SESSION = None
    _AD_LAST_CACHE.clear()
    _UPSERT_LAST_CACHE.clear()
    _OP_GATE_CACHE.clear()




def compact_json(value: Any, limit: int = 5000) -> str:
    try:
        text_value = json.dumps(value, ensure_ascii=False, default=str)
    except Exception:
        text_value = str(value)
    if len(text_value) > limit:
        return text_value[:limit] + "…"
    return text_value


def safe_response_summary(value: Any, limit: int = 700) -> str:
    if value is None:
        return "нет ответа"
    if isinstance(value, dict):
        parts: list[str] = []
        for key in ("status", "ok", "success", "completed", "skip", "prev_success", "error", "message", "description"):
            if key in value:
                parts.append(f"{key}={value.get(key)!r}")
        if "sponsors" in value and isinstance(value.get("sponsors"), list):
            parts.append(f"sponsors={len(value.get('sponsors') or [])}")
        if "tasks" in value and isinstance(value.get("tasks"), list):
            parts.append(f"tasks={len(value.get('tasks') or [])}")
        if not parts:
            parts.append(compact_json(value, 350))
        text_value = "; ".join(parts)
    else:
        text_value = str(value)
    return text_value[:limit] + ("…" if len(text_value) > limit else "")


async def log_provider_event(
    provider: str,
    event: str,
    *,
    user_id: int | None = None,
    chat_id: int | None = None,
    status: str = "info",
    http_status: int | None = None,
    duration_ms: int | None = None,
    request: Any = None,
    response: Any = None,
    error: Exception | str | None = None,
) -> None:
    if await get_setting("provider_logs_enabled", "1") != "1":
        return
    try:
        async with await db() as conn:
            await conn.execute(
                "INSERT INTO provider_event_logs(provider,event,user_id,chat_id,status,http_status,duration_ms,request_json,response_json,error,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (
                    provider,
                    event,
                    int(user_id) if user_id is not None else None,
                    int(chat_id) if chat_id is not None else None,
                    status,
                    int(http_status) if http_status is not None else None,
                    int(duration_ms) if duration_ms is not None else None,
                    compact_json(request, 2500) if request is not None else None,
                    compact_json(response, 5000) if response is not None else None,
                    str(error)[:1000] if error is not None else None,
                    now_iso(),
                ),
            )
            cleanup_interval = await get_int_setting("maintenance_cleanup_interval_seconds", 600)
            if _maintenance_due("provider_event_logs", cleanup_interval):
                keep_days = max(1, await get_int_setting("provider_logs_keep_days", 7))
                border = (datetime.now(timezone.utc) - timedelta(days=keep_days)).isoformat(timespec="seconds")
                await conn.execute("DELETE FROM provider_event_logs WHERE created_at < ?", (border,))
            await conn.commit()
    except Exception as e:
        log.debug("provider event log skipped: %s", e)


async def fixed_task_reward(provider: str, api_reward: float | None = None) -> float:
    mapping = {
        "piarflow": ("default_task_reward", 0.25),
        "botohub": ("default_task_reward_alt", 0.3),
        "subgram": ("default_subgram_task_reward", 0.25),
    }
    key, default = mapping.get(provider, ("default_task_reward", 0.25))
    if await get_setting("task_fixed_rewards_enabled", "1") == "1" or api_reward is None or float(api_reward or 0) <= 0:
        return await get_float_setting(key, default)
    try:
        reward = float(api_reward)
        return reward if reward > 0 else await get_float_setting(key, default)
    except Exception:
        return await get_float_setting(key, default)

async def send_message_draft(chat_id: int, text: str) -> None:
    """Stream a temporary Telegram draft before sending the final message.

    sendMessageDraft is ephemeral; the real persisted message is still sent by
    message.answer()/bot.send_message() after this preview.
    """
    if await get_setting("message_draft_animation_enabled", "0") != "1":
        return
    token = (await get_setting("bot_token", BOT_TOKEN)).strip() or BOT_TOKEN
    if not token:
        return
    plain = plain_text_for_draft(text)
    steps = max(1, min(await get_int_setting("message_draft_animation_steps", 3), 5))
    draft_id = int(time.time() * 1000) % 2147480000 + random.randint(1, 3000)
    chunks = [""]
    if plain:
        length = min(len(plain), 900)
        for i in range(1, steps + 1):
            cut = max(1, int(length * i / steps))
            chunks.append(plain[:cut])
    url = f"https://api.telegram.org/bot{token}/sendMessageDraft"
    try:
        async with await http_session_context() as session:
            for chunk in chunks:
                payload = {"chat_id": chat_id, "draft_id": draft_id, "text": chunk}
                async with session.post(url, json=payload, timeout=5) as resp:
                    await resp.read()
                await asyncio.sleep(0.16)
    except Exception as e:
        log.debug("sendMessageDraft skipped: %s", e)




async def remember_bot_message(sent_message: Message | None, scope: str = "general", user_id: int | None = None) -> None:
    """Store bot message ids so old UI/task messages can be removed later."""
    if sent_message is None or await get_setting("cleanup_bot_messages_enabled", "1") != "1":
        return
    chat = getattr(sent_message, "chat", None)
    message_id = getattr(sent_message, "message_id", None)
    if not chat or message_id is None:
        return
    # In private chats chat.id == user_id. For callbacks we may pass user_id explicitly.
    resolved_user_id = int(user_id or getattr(chat, "id", 0) or 0)
    try:
        async with await db() as conn:
            await conn.execute(
                "INSERT INTO bot_message_logs(user_id,chat_id,message_id,scope,created_at) VALUES(?,?,?,?,?)",
                (resolved_user_id, int(chat.id), int(message_id), scope, now_iso()),
            )
            cleanup_interval = await get_int_setting("maintenance_cleanup_interval_seconds", 600)
            if _maintenance_due("bot_message_logs", cleanup_interval):
                keep_days = max(1, await get_int_setting("cleanup_deleted_rows_after_days", 2))
                border = (datetime.now(timezone.utc) - timedelta(days=keep_days)).isoformat(timespec="seconds")
                await conn.execute("DELETE FROM bot_message_logs WHERE created_at < ?", (border,))
            await conn.commit()
    except Exception as e:
        log.debug("remember_bot_message skipped: %s", e)


async def cleanup_bot_messages(
    message: Message,
    user_id: int | None = None,
    *,
    scopes: str | list[str] | tuple[str, ...] | None = None,
    keep_message_ids: set[int] | None = None,
    limit: int = 80,
) -> int:
    """Delete previously sent bot messages for a user/chat without holding a SQLite write lock.

    v27 optimization: first fetch row ids, close the DB connection, then call Telegram
    delete_message. Network calls while a SQLite connection is open were one of the
    biggest sources of slow responses and database lock contention.
    """
    if await get_setting("cleanup_bot_messages_enabled", "1") != "1":
        return 0
    chat = getattr(message, "chat", None)
    bot = getattr(message, "bot", None)
    if not chat or not bot:
        return 0

    chat_id = int(chat.id)
    resolved_user_id = int(user_id or chat_id)
    keep_message_ids = keep_message_ids or set()
    if scopes is None:
        scope_list: list[str] | None = None
    elif isinstance(scopes, str):
        scope_list = [scopes]
    else:
        scope_list = [str(x) for x in scopes]

    rows_data: list[tuple[int, int]] = []
    try:
        async with await db() as conn:
            if scope_list:
                placeholders = ",".join("?" for _ in scope_list)
                cur = await conn.execute(
                    f"SELECT id, message_id FROM bot_message_logs WHERE user_id=? AND chat_id=? AND scope IN ({placeholders}) ORDER BY id DESC LIMIT ?",
                    (resolved_user_id, chat_id, *scope_list, int(limit)),
                )
            else:
                cur = await conn.execute(
                    "SELECT id, message_id FROM bot_message_logs WHERE user_id=? AND chat_id=? ORDER BY id DESC LIMIT ?",
                    (resolved_user_id, chat_id, int(limit)),
                )
            rows = await cur.fetchall()
            rows_data = [(int(row["id"]), int(row["message_id"])) for row in rows]
    except Exception as e:
        log.debug("cleanup_bot_messages fetch skipped: %s", e)
        return 0

    if not rows_data:
        return 0

    pause_ms = max(0, min(await get_int_setting("telegram_delete_pause_ms", 0), 200))
    deleted = 0
    row_ids: list[int] = []
    for row_id, mid in rows_data:
        row_ids.append(row_id)
        if mid in keep_message_ids:
            continue
        try:
            await bot.delete_message(chat_id=chat_id, message_id=mid)
            deleted += 1
            if pause_ms:
                await asyncio.sleep(pause_ms / 1000)
        except (TelegramBadRequest, TelegramForbiddenError):
            pass
        except Exception as e:
            log.debug("delete_message skipped: %s", e)

    try:
        async with await db() as conn:
            placeholders = ",".join("?" for _ in row_ids)
            await conn.execute(f"DELETE FROM bot_message_logs WHERE id IN ({placeholders})", tuple(row_ids))
            await conn.commit()
    except Exception as e:
        log.debug("cleanup_bot_messages row cleanup skipped: %s", e)
    return deleted

async def cleanup_task_flow(message: Message, user_id: int | None = None) -> int:
    if await get_setting("cleanup_task_messages_enabled", "1") != "1":
        return 0
    return await cleanup_bot_messages(message, user_id, scopes=["task", "task_status", "task_header"])


async def cleanup_general_flow(message: Message, user_id: int | None = None) -> int:
    if await get_setting("cleanup_general_messages_enabled", "0") != "1":
        return 0
    return await cleanup_bot_messages(message, user_id, scopes=["general", "menu", "task", "task_status", "task_header", "game", "game_dice", "game_result"])

async def animated_answer(message: Message, text: str, **kwargs: Any) -> Message:
    """Show animated Telegram draft, send final message and remember it for cleanup.

    This helper is intentionally tolerant: if Telegram rejects rich HTML/custom
    emoji entities, it retries with plain fallback emoji, then with plain text.
    A bad premium emoji id must not break admin navigation or user flows.
    """
    track_scope = str(kwargs.pop("track_scope", "general"))
    track_user_id = kwargs.pop("track_user_id", None)
    parse_mode = kwargs.get("parse_mode", ParseMode.HTML)
    variants = safe_text_variants(str(text or ""), parse_mode=parse_mode)

    try:
        if getattr(message, "chat", None) and getattr(message.chat, "type", None) == "private":
            # Drafts are cosmetic; use the safest readable preview so decoration
            # cannot slow down or break the actual send.
            await send_message_draft(message.chat.id, strip_tg_emoji_tags(variants[0][0]))
    except Exception as e:
        log.debug("Draft animation failed: %s", e)

    last_error: Exception | None = None
    original_markup = kwargs.get("reply_markup")
    markup_variants = [original_markup]
    no_icon_markup = strip_inline_keyboard_icons(original_markup) if isinstance(original_markup, InlineKeyboardMarkup) else original_markup
    if no_icon_markup is not original_markup:
        markup_variants.append(no_icon_markup)
    for markup in markup_variants:
        for value, mode in variants:
            send_kwargs = dict(kwargs)
            send_kwargs["parse_mode"] = mode
            if markup is not original_markup:
                send_kwargs["reply_markup"] = markup
            try:
                sent = await message.answer(value, **send_kwargs)
                await remember_bot_message(sent, scope=track_scope, user_id=track_user_id)
                return sent
            except TelegramBadRequest as e:
                last_error = e
                log.warning("message.answer failed, retrying with safer text/markup: %s", e)
                continue

    # Last-resort minimal message. If this fails too, let aiogram log it.
    sent = await message.answer("Сообщение не удалось отобразить полностью.", parse_mode=None)
    await remember_bot_message(sent, scope=track_scope, user_id=track_user_id)
    if last_error:
        log.error("All rich text send attempts failed: %s", last_error)
    return sent



def mask_secret(value: str) -> str:
    value = value or ""
    if not value:
        return "не задан"
    if len(value) <= 10:
        return "••••"
    return f"{value[:4]}••••{value[-4:]}"


def bool_title(value: str) -> str:
    return "✅ включено" if str(value) == "1" else "❌ выключено"


def setting_meta(key: str) -> dict:
    return SETTINGS_META.get(key, {"title": key, "category": "other", "kind": "text", "desc": "Пользовательская настройка."})


def setting_category(key: str) -> str:
    return setting_meta(key).get("category", "other")


def setting_value_for_display(key: str, value: str) -> str:
    meta = setting_meta(key)
    kind = meta.get("kind", "text")
    if kind == "secret":
        return mask_secret(value)
    if kind == "bool":
        return bool_title(value)
    return value if value != "" else "не задано"


def normalize_setting_value(key: str, raw_value: str) -> tuple[bool, str, str]:
    meta = setting_meta(key)
    kind = meta.get("kind", "text")
    value = raw_value.strip() if kind != "text" else raw_value

    if kind == "bool":
        lowered = value.lower()
        if lowered in {"1", "true", "yes", "y", "да", "on", "вкл", "включить", "включено"}:
            return True, "1", ""
        if lowered in {"0", "false", "no", "n", "нет", "off", "выкл", "выключить", "выключено"}:
            return True, "0", ""
        return False, "", "Введите 1/0, да/нет или вкл/выкл."

    if kind == "enum":
        options = meta.get("options", [])
        if value not in options:
            return False, "", "Выберите одно из значений: " + ", ".join(options)
        return True, value, ""

    if kind == "int":
        try:
            return True, str(int(value)), ""
        except Exception:
            return False, "", "Введите целое число."

    if kind == "float":
        try:
            num = float(value.replace(",", "."))
            return True, fmt_amount(num), ""
        except Exception:
            return False, "", "Введите число. Например: 0.25"

    if kind == "csv_int":
        parts = [p.strip() for p in value.split(",") if p.strip()]
        if not parts:
            return True, "", ""
        if not all(p.isdigit() for p in parts):
            return False, "", "Введите ID через запятую, только цифры."
        return True, ",".join(parts), ""

    if kind == "csv_float":
        parts = [p.strip().replace(",", ".") for p in value.replace(";", ",").split(",") if p.strip()]
        if not parts:
            return True, "", ""
        try:
            nums = [fmt_amount(float(p)) for p in parts]
        except Exception:
            return False, "", "Введите числа через запятую. Например: 15,25,50,100"
        return True, ",".join(nums), ""

    return True, value, ""


async def safe_edit_or_answer(message: Message, text: str, reply_markup: InlineKeyboardMarkup | None = None, parse_mode: ParseMode | str | None = ParseMode.HTML) -> None:
    """Edit a message without letting bad HTML/custom emoji break navigation."""
    variants = safe_text_variants(str(text or ""), parse_mode=parse_mode)
    last_error: Exception | None = None

    markup_variants = [reply_markup]
    no_icon_markup = strip_inline_keyboard_icons(reply_markup) if isinstance(reply_markup, InlineKeyboardMarkup) else reply_markup
    if no_icon_markup is not reply_markup:
        markup_variants.append(no_icon_markup)
    for markup in markup_variants:
        for value, mode in variants:
            try:
                await message.edit_text(value, reply_markup=markup, parse_mode=mode)
                return
            except TelegramBadRequest as e:
                last_error = e
                if is_message_not_modified_error(e):
                    return
                log.warning("message.edit_text failed, retrying with safer text/markup: %s", e)
                continue

    # If the original message cannot be edited at all, send a fresh safe one.
    fallback_text, fallback_mode = variants[-1]
    fallback_markup = strip_inline_keyboard_icons(reply_markup) if isinstance(reply_markup, InlineKeyboardMarkup) else reply_markup
    try:
        await message.answer(fallback_text, reply_markup=fallback_markup, parse_mode=fallback_mode)
    except TelegramBadRequest:
        await message.answer("Раздел открыт, но текст не удалось отобразить полностью.", reply_markup=fallback_markup, parse_mode=None)
    if last_error:
        log.error("All edit attempts failed: %s", last_error)



async def settings_home_text() -> str:
    return (
        f"{ce('settings', '⚙')} <b>Панель настроек</b>\n\n"
        f"<i>Здесь собраны все параметры бота: API, экономика, меню и тексты.</i>\n\n"
        f"<blockquote>Переключатели меняются одним нажатием. Тексты можно отправлять обычным форматированным сообщением Telegram.</blockquote>"
    )


def settings_home_kb() -> InlineKeyboardMarkup:
    rows = []
    for cat, data in SETTINGS_CATEGORIES.items():
        rows.append([ibtn(data["title"], callback_data=f"cfg:cat:{cat}", icon=BUTTON_ICON.get(cat))])
    rows.append([ibtn("В админ-панель", callback_data="admin:menu", icon="back")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def settings_category_text(category: str) -> str:
    data = SETTINGS_CATEGORIES[category]
    return f"{data['title']}\n\n{html.escape(data['description'])}\n\nВыберите параметр для просмотра и изменения."


async def settings_category_kb(category: str) -> InlineKeyboardMarkup:
    data = SETTINGS_CATEGORIES[category]
    rows = []
    for key in data["keys"]:
        meta = setting_meta(key)
        value = await get_setting(key, str(DEFAULT_SETTINGS.get(key, "")))
        short_value = setting_value_for_display(key, value)
        if len(short_value) > 24:
            short_value = short_value[:21] + "..."
        rows.append([ibtn(f"{meta['title']}: {short_value}", callback_data=f"cfg:key:{key}", icon=BUTTON_ICON.get(category))])
    rows.append([
        ibtn("Разделы", callback_data="cfg:home", icon="back"),
        ibtn("Админка", callback_data="admin:menu", icon="home"),
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def setting_card_text(key: str) -> str:
    meta = setting_meta(key)
    value = await get_setting(key, str(DEFAULT_SETTINGS.get(key, "")))
    shown = setting_value_for_display(key, value)
    if len(shown) > 2800:
        shown = shown[:2800] + "\n…"

    lines = [
        f"{ce('settings', '⚙')} <b>{html.escape(meta.get('title', key))}</b>",
        f"<code>{html.escape(key)}</code>",
        "",
        f"{html.escape(meta.get('desc', ''))}",
    ]

    if is_rich_text_setting(key):
        preview = value or "не задано"
        if len(preview) > 2800:
            preview = preview[:2800] + "\n…"
        lines.extend([
            "",
            f"{ce('eye', '👁')} <b>Предпросмотр:</b>",
            render_bot_text(preview),
            "",
            f"{ce('info', 'ℹ')} Чтобы изменить текст, отправьте обычное сообщение с нужным оформлением Telegram. Жирный, курсив, подчёркивание, цитаты, ссылки и любые premium emoji сохранятся автоматически — HTML писать не нужно.",
        ])
    else:
        lines.extend([
            "",
            "<b>Текущее значение:</b>",
            f"<code>{html.escape(shown)}</code>",
        ])

    if key == "bot_token":
        lines.append(f"\n{ce('info', 'ℹ')} Новый токен Telegram-бота применится после перезапуска процесса.")
    if meta.get("placeholder"):
        lines.append(f"\nПример: <code>{html.escape(str(meta['placeholder']))}</code>")
    if meta.get("options"):
        lines.append("\nВарианты: " + ", ".join(f"<code>{html.escape(str(x))}</code>" for x in meta["options"]))
    return "\n".join(lines)



async def setting_card_kb(key: str) -> InlineKeyboardMarkup:
    meta = setting_meta(key)
    kind = meta.get("kind", "text")
    rows = []

    if kind == "bool":
        current = await get_setting(key, str(DEFAULT_SETTINGS.get(key, "0")))
        rows.append([ibtn("Переключить" + (" на выкл" if current == "1" else " на вкл"), callback_data=f"cfg:toggle:{key}", icon="toggle")])

    if kind == "enum":
        current = await get_setting(key, str(DEFAULT_SETTINGS.get(key, "")))
        option_buttons = []
        for option in meta.get("options", []):
            mark = "✅ " if option == current else ""
            option_buttons.append(ibtn(f"{mark}{option}", callback_data=f"cfg:set:{key}:{option}", icon="check" if option == current else "settings"))
        for i in range(0, len(option_buttons), 2):
            rows.append(option_buttons[i:i + 2])

    rows.append([ibtn("Изменить", callback_data=f"cfg:edit:{key}", icon="edit")])
    rows.append([
        ibtn("По умолчанию", callback_data=f"cfg:default:{key}", icon="time_passed"),
        ibtn("Очистить", callback_data=f"cfg:clear:{key}", icon="trash"),
    ])
    rows.append([
        ibtn("Назад", callback_data=f"cfg:cat:{setting_category(key)}", icon="back"),
        ibtn("Админка", callback_data="admin:menu", icon="home"),
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def cancel_input_kb(key: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Отмена", callback_data=f"cfg:key:{key}", icon="cancel")],
        [ibtn("Админка", callback_data="admin:menu", icon="home")],
    ])


async def is_admin(user_id: int) -> bool:
    # ADMIN_IDS из .env остаются аварийным доступом, а список из БД можно менять через админку.
    if user_id in ADMIN_IDS:
        return True
    try:
        admin_ids_raw = await get_setting("admin_ids", ADMIN_IDS_RAW)
        admin_ids = {int(x.strip()) for x in admin_ids_raw.split(",") if x.strip().isdigit()}
        return user_id in admin_ids
    except Exception:
        return False


async def main_menu(user_id: int | None = None) -> ReplyKeyboardMarkup:
    keyboard = [
        [kbtn("Заработать звёзды", "send_money"), kbtn("Вывести звёзды", "accept_money")],
        [kbtn("Задания", "check"), kbtn("Бонус и игры", "gift")],
        [kbtn(await get_setting("profile_button_text", str(DEFAULT_SETTINGS["profile_button_text"])), "profile")],
    ]

    if await get_setting("buy_stars_button_enabled", "1") == "1":
        keyboard.append([kbtn(await get_setting("buy_stars_button_text", str(DEFAULT_SETTINGS["buy_stars_button_text"])), "money")])

    if user_id is not None and await is_admin(user_id):
        keyboard.append([kbtn(await get_setting("admin_panel_button_text", str(DEFAULT_SETTINGS["admin_panel_button_text"])), "settings")])

    return ReplyKeyboardMarkup(keyboard=keyboard, resize_keyboard=True)


async def bonus_menu(user_id: int | None = None) -> InlineKeyboardMarkup:
    bet = await get_user_game_bet(user_id) if user_id is not None else await get_float_setting("game_default_bet", 1.0)
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Слоты", callback_data="game:play:slots", icon="gift"), ibtn("Кости", callback_data="game:play:dice", icon="apps")],
        [ibtn("Баскетбол", callback_data="game:play:basket", icon="party"), ibtn("Боулинг", callback_data="game:play:bowling", icon="box")],
        [ibtn(f"{fmt_amount(bet)} | Изменить ставку", callback_data="game:bet", icon="star")],
        [ibtn("Получить ежедневный бонус", callback_data="daily_bonus", icon="gift")],
    ])


ADMIN_SECTIONS = {
    "users": {
        "title": "Пользователи",
        "icon": "people",
        "description": "Поиск пользователя, баланс, бан, ОП и история действий.",
        "buttons": [
            [("Найти пользователя", "admin:users", "people"), ("Статистика", "admin:stats", "stats")],
            [("Заявки на вывод", "admin:withdrawals", "wallet"), ("Чеки", "admin:checks", "gift")],
            [("Промокоды", "admin:promos", "tag")],
        ],
    },
    "finance": {
        "title": "Финансы",
        "icon": "wallet",
        "description": "Выводы, суммы, канал выплат и базовые параметры экономики.",
        "buttons": [
            [("Заявки на вывод", "admin:withdrawals", "wallet"), ("Канал выплат", "cfg:key:payout_channel_chat_id", "broadcast")],
            [("Суммы вывода", "cfg:key:withdraw_amounts", "star"), ("Подарки вывода", "cfg:key:withdraw_gifts_enabled", "gift")],
            [("Мин. рефералов", "cfg:key:withdraw_min_referrals", "people"), ("Свежесть ОП", "cfg:key:op_recheck_interval_minutes", "clock")],
            [("Награда за задание", "cfg:key:default_task_reward", "star"), ("Реферальная награда", "cfg:key:ref_reward", "send_money")],
            [("Экономика", "cfg:cat:economy", "money")],
        ],
    },
    "marketing": {
        "title": "Маркетинг",
        "icon": "growth",
        "description": "UTM-ссылки, рассылки, промокоды и рекламные показы HiViews/BotoHub Views.",
        "buttons": [
            [("UTM-статистика", "admin:utm", "growth"), ("Создать ссылку", "admin:create_link", "link")],
            [("Рассылка", "admin:broadcast", "broadcast"), ("Чеки", "admin:checks", "gift")],
            [("Промокоды", "admin:promos", "tag")],
            [("Start-провайдер", "cfg:key:start_ad_provider", "eye"), ("HiViews key", "cfg:key:hiviews_api_key", "apps")],
            [("Views вне /start", "cfg:key:botohub_views_regular_enabled", "eye"), ("Шанс Views", "cfg:key:botohub_views_regular_chance_percent", "stats")],
        ],
    },
    "integrations": {
        "title": "Интеграции",
        "icon": "apps",
        "description": "SubGram, BotoHub, PiarFlow, роли провайдеров и диагностика API.",
        "buttons": [
            [("Диагностика", "admin:diagnostics", "info"), ("API-токены", "admin:api", "apps")],
            [("Провайдер ОП", "cfg:key:op_provider", "lock"), ("Провайдер заданий", "cfg:key:tasks_provider", "check")],
            [("SubGram", "cfg:key:provider_role_subgram", "subscribe"), ("BotoHub", "cfg:key:provider_role_botohub", "bot")],
            [("PiarFlow", "cfg:key:provider_role_piarflow", "link"), ("Start-реклама", "cfg:key:start_ad_provider", "eye")],
            [("BotoHub Views", "cfg:key:botohub_views_token", "eye"), ("HiViews", "cfg:key:hiviews_api_key", "apps")],
        ],
    },
    "content": {
        "title": "Контент и меню",
        "icon": "write",
        "description": "Тексты бота, главное меню, кнопки и стартовый сценарий.",
        "buttons": [
            [("Все тексты", "cfg:cat:texts", "write"), ("Главное меню", "cfg:cat:menu", "home")],
            [("Стартовый текст", "cfg:key:start_text", "party"), ("Бонусный блок", "cfg:key:start_bonus_text", "gift")],
            [("Текст задания", "cfg:key:task_text", "check"), ("Профиль", "cfg:key:profile_text", "profile")],
        ],
    },
    "games": {
        "title": "Игры и бонусы",
        "icon": "gift",
        "description": "Мини-игры, ставки, ежедневный бонус и оформление игровых сообщений.",
        "buttons": [
            [("Ставка по умолчанию", "cfg:key:game_default_bet", "star"), ("Быстрые ставки", "cfg:key:game_bet_presets", "star")],
            [("Анимация игр", "cfg:key:game_animation_enabled", "apps"), ("Задержка результата", "cfg:key:game_animation_result_delay", "clock")],
            [("Мин. бонус", "cfg:key:daily_bonus_min", "gift"), ("Макс. бонус", "cfg:key:daily_bonus_max", "gift")],
        ],
    },
    "system": {
        "title": "Система",
        "icon": "settings",
        "description": "Производительность, кэш, очистка сообщений, администраторы и токен бота.",
        "buttons": [
            [("Быстрый режим", "cfg:key:performance_mode_enabled", "loading"), ("Кэш настроек", "cfg:key:settings_cache_ttl_seconds", "clock")],
            [("Удаление сообщений", "cfg:key:cleanup_bot_messages_enabled", "trash"), ("Анимация черновика", "cfg:key:message_draft_animation_enabled", "write")],
            [("Администраторы", "cfg:key:admin_ids", "people"), ("Токен бота", "cfg:key:bot_token", "bot")],
            [("Все настройки", "admin:settings", "settings"), ("Диагностика", "admin:diagnostics", "info")],
        ],
    },
}


def admin_menu() -> InlineKeyboardMarkup:
    """Compact admin dashboard: sections first, detailed actions inside sections."""
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Обзор", callback_data="admin:menu", icon="stats")],
        [ibtn("Пользователи", callback_data="admin:section:users", icon="people"), ibtn("Финансы", callback_data="admin:section:finance", icon="wallet")],
        [ibtn("Маркетинг", callback_data="admin:section:marketing", icon="growth"), ibtn("Интеграции", callback_data="admin:section:integrations", icon="apps")],
        [ibtn("Контент и меню", callback_data="admin:section:content", icon="write"), ibtn("Игры и бонусы", callback_data="admin:section:games", icon="gift")],
        [ibtn("Система", callback_data="admin:section:system", icon="settings"), ibtn("Диагностика", callback_data="admin:diagnostics", icon="info")],
    ])


def admin_section_kb(section: str) -> InlineKeyboardMarkup:
    data = ADMIN_SECTIONS.get(section)
    if not data:
        return admin_menu()
    rows = []
    for row in data["buttons"]:
        rows.append([ibtn(title, callback_data=callback, icon=icon) for title, callback, icon in row])
    rows.append([
        ibtn("Обзор", callback_data="admin:menu", icon="stats"),
        ibtn("Все настройки", callback_data="admin:settings", icon="settings"),
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def admin_dashboard_text() -> str:
    today_border = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat(timespec="seconds")
    async with await db() as conn:
        queries = {
            "users": "SELECT COUNT(*) c FROM users",
            "active": "SELECT COUNT(*) c FROM users WHERE last_seen >= ?",
            "op": "SELECT COUNT(*) c FROM users WHERE is_op_passed=1",
            "banned": "SELECT COUNT(*) c FROM users WHERE is_banned=1",
            "pending_wd": "SELECT COUNT(*) c FROM withdraw_requests WHERE status='pending'",
            "pending_sum": "SELECT COALESCE(SUM(amount),0) c FROM withdraw_requests WHERE status='pending'",
            "done_tasks": "SELECT COUNT(*) c FROM task_logs WHERE status='done'",
            "balance": "SELECT COALESCE(SUM(balance),0) c FROM users",
        }
        stats: dict[str, Any] = {}
        for name, sql in queries.items():
            args = (today_border,) if name == "active" else ()
            cur = await conn.execute(sql, args)
            stats[name] = (await cur.fetchone())["c"]

    users = int(stats.get("users") or 0)
    op = int(stats.get("op") or 0)
    conv = (op / users * 100) if users else 0
    op_provider = html.escape(await get_setting("op_provider", "auto"))
    task_provider = html.escape(await get_setting("tasks_provider", "auto"))
    fast_mode = bool_title(await get_setting("performance_mode_enabled", "1"))
    payout_channel = bool_title(await get_setting("payout_channel_enabled", "0"))

    return "\n".join([
        f"{ce('settings', '⚙')} <b>Админ-панель</b>",
        "",
        "<blockquote>Главные разделы собраны по смыслу. Сначала выберите направление, затем конкретное действие.</blockquote>",
        "",
        f"{ce('stats', '📊')} <b>Сегодня и сейчас</b>",
        f"• Пользователей: <b>{users}</b> · активных 24ч: <b>{int(stats.get('active') or 0)}</b>",
        f"• ОП пройдена: <b>{op}</b> (<b>{conv:.1f}%</b>) · банов: <b>{int(stats.get('banned') or 0)}</b>",
        f"• Выполнено заданий: <b>{int(stats.get('done_tasks') or 0)}</b>",
        f"• Pending выводов: <b>{int(stats.get('pending_wd') or 0)}</b> на <b>{star_amount(float(stats.get('pending_sum') or 0))}</b>",
        f"• Баланс пользователей: <b>{star_amount(float(stats.get('balance') or 0))}</b>",
        "",
        f"{ce('apps', '📦')} <b>Режимы</b>",
        f"• ОП: <code>{op_provider}</code> · задания: <code>{task_provider}</code>",
        f"• Канал выплат: {payout_channel}",
        f"• Быстрый режим: {fast_mode}",
    ])


async def admin_section_text(section: str) -> str:
    data = ADMIN_SECTIONS.get(section)
    if not data:
        return await admin_dashboard_text()
    return "\n".join([
        f"{ce(data.get('icon', 'settings'), '•')} <b>{html.escape(data['title'])}</b>",
        "",
        f"<i>{html.escape(data['description'])}</i>",
        "",
        "<blockquote>Выберите нужное действие ниже. Кнопка «Обзор» вернёт на главный экран админки.</blockquote>",
    ])


async def upsert_user(message: Message, source_code: str | None = None) -> None:
    user = message.from_user
    if not user:
        return
    # v27 optimization: middleware calls upsert_user on ordinary messages only to refresh last_seen.
    # Do not write to SQLite on every click/message from the same user.
    if source_code is None:
        try:
            interval = max(0, await get_int_setting("last_seen_update_interval_seconds", 45))
        except Exception:
            interval = 45
        last = _UPSERT_LAST_CACHE.get(int(user.id), 0.0)
        if interval > 0 and time.monotonic() - last < interval:
            return
    referrer_id = None
    source = source_code
    if source_code and source_code.startswith("ref_"):
        try:
            rid = int(source_code.split("_", 1)[1])
            if rid != user.id:
                referrer_id = rid
                source = source_code
        except Exception:
            pass
    async with await db() as conn:
        cur = await conn.execute("SELECT id, referrer_id, source_code FROM users WHERE id=?", (user.id,))
        row = await cur.fetchone()
        if row is None:
            await conn.execute(
                "INSERT INTO users(id,username,first_name,referrer_id,source_code,created_at,last_seen) VALUES(?,?,?,?,?,?,?)",
                (user.id, user.username, user.first_name, referrer_id, source, now_iso(), now_iso()),
            )
        else:
            await conn.execute(
                "UPDATE users SET username=?, first_name=?, last_seen=?, source_code=COALESCE(source_code, ?), referrer_id=COALESCE(referrer_id, ?) WHERE id=?",
                (user.username, user.first_name, now_iso(), source, referrer_id, user.id),
            )
        if source and not source.startswith("ref_"):
            cur_deleted = await conn.execute("SELECT 1 FROM utm_deleted_links WHERE code=?", (source,))
            if await cur_deleted.fetchone() is None:
                await conn.execute("INSERT OR IGNORE INTO utm_links(code,title,created_at) VALUES(?,?,?)", (source, source, now_iso()))
        await conn.commit()
    # User fields/referral/source may have changed; do not serve a stale cached row.
    _UPSERT_LAST_CACHE[int(user.id)] = time.monotonic()
    invalidate_user_cache(user.id)


def invalidate_user_cache(user_id: int | None = None) -> None:
    if user_id is None:
        _USER_CACHE.clear()
    else:
        _USER_CACHE.pop(int(user_id), None)


async def get_user(user_id: int) -> Optional[dict[str, Any]]:
    try:
        ttl = int(_SETTINGS_CACHE.get("user_cache_ttl_seconds", "2") or 0)
    except Exception:
        ttl = 2
    now_mono = time.monotonic()
    cached = _USER_CACHE.get(int(user_id))
    if ttl > 0 and cached and now_mono - cached[0] < ttl:
        return cached[1]
    async with await db() as conn:
        cur = await conn.execute("SELECT * FROM users WHERE id=?", (user_id,))
        row = await cur.fetchone()
    data = dict(row) if row else None
    if ttl > 0:
        if len(_USER_CACHE) > 4096:
            _USER_CACHE.clear()
        _USER_CACHE[int(user_id)] = (now_mono, data)
    return data


async def add_balance(user_id: int, amount: float) -> None:
    async with await db() as conn:
        await conn.execute("UPDATE users SET balance = balance + ? WHERE id=?", (amount, user_id))
        await conn.commit()
    invalidate_user_cache(user_id)


async def mark_op_passed(user_id: int) -> None:
    row = await get_user(user_id)
    if not row:
        return
    ref_reward = await get_float_setting("ref_reward", 4.5)
    async with await db() as conn:
        # Обновляем op_passed_at при каждой успешной проверке.
        # Это нужно для правила: ОП должна быть свежей, например не старше 30 минут.
        await conn.execute("UPDATE users SET is_op_passed=1, op_passed_at=? WHERE id=?", (now_iso(), user_id))
        # Реферальную награду начисляем строго один раз, как и раньше.
        if row["referrer_id"] and not row["ref_rewarded"]:
            await conn.execute("UPDATE users SET balance = balance + ?, invited_count = invited_count + 1 WHERE id=?", (ref_reward, row["referrer_id"]))
            await conn.execute("UPDATE users SET ref_rewarded=1 WHERE id=?", (user_id,))
        await conn.commit()
    invalidate_user_cache(user_id)
    _invalidate_op_gate_cache(user_id)
    if row["referrer_id"]:
        invalidate_user_cache(row["referrer_id"])


def is_op_fresh(row: dict[str, Any] | None, interval_minutes: int) -> bool:
    if not row or not int(row.get("is_op_passed") or 0):
        return False
    if interval_minutes <= 0:
        return True
    passed_at = parse_dt(row.get("op_passed_at"))
    if not passed_at:
        return False
    if passed_at.tzinfo is None:
        passed_at = passed_at.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) - passed_at < timedelta(minutes=interval_minutes)


async def expire_op_if_stale(user_id: int, row: dict[str, Any] | None = None) -> bool:
    interval = max(1, await get_int_setting("op_recheck_interval_minutes", 30))
    row = row or await get_user(user_id)
    if is_op_fresh(row, interval):
        return False
    if row and int(row.get("is_op_passed") or 0):
        async with await db() as conn:
            await conn.execute("UPDATE users SET is_op_passed=0 WHERE id=?", (int(user_id),))
            await conn.commit()
        invalidate_user_cache(user_id)
        _invalidate_op_gate_cache(user_id)
    return True


async def ensure_fresh_op_for_withdraw(message: Message, user: Any | None = None) -> bool:
    user = user or getattr(message, "from_user", None)
    if not user:
        return False
    if await get_setting("withdraw_requires_fresh_op", "1") != "1":
        return True
    row = await get_user(int(user.id))
    await expire_op_if_stale(int(user.id), row)
    row = await get_user(int(user.id))
    interval = max(1, await get_int_setting("op_recheck_interval_minutes", 30))
    if is_op_fresh(row, interval):
        return True

    allowed, text, markup = await process_op(user, message.chat.id)
    if allowed:
        return True
    await animated_answer(message, text or await get_setting("op_text"), reply_markup=markup)
    return False


async def ensure_fresh_op_for_withdraw_callback(callback: CallbackQuery) -> bool:
    if await get_setting("withdraw_requires_fresh_op", "1") != "1":
        return True
    message = callback.message
    if not message:
        await callback.answer("Сначала пройдите ОП", show_alert=True)
        return False

    row = await get_user(int(callback.from_user.id))
    await expire_op_if_stale(int(callback.from_user.id), row)
    row = await get_user(int(callback.from_user.id))
    interval = max(1, await get_int_setting("op_recheck_interval_minutes", 30))
    if is_op_fresh(row, interval):
        return True

    await callback.answer("Сначала пройдите обязательную подписку", show_alert=True)
    allowed, text, markup = await process_op(callback.from_user, message.chat.id)
    if allowed:
        return True
    await safe_edit_or_answer(message, text or await get_setting("op_text"), reply_markup=markup, parse_mode=ParseMode.HTML)
    return False


async def ensure_fresh_op_for_usage_message(message: Message, user: Any | None = None) -> bool:
    """Gate ordinary user actions when OP is missing or older than the configured interval."""
    user = user or getattr(message, "from_user", None)
    if not user:
        return True
    uid = int(user.id)

    # A very short cache removes repeated SQLite reads when a user taps several buttons quickly.
    if _op_gate_cache_ok(uid, "usage"):
        return True

    interval = max(1, await get_int_setting("op_recheck_interval_minutes", 30))
    row = await get_user(uid)
    if is_op_fresh(row, interval):
        await _remember_op_gate_ok(uid, "usage")
        return True

    if row and int(row.get("is_op_passed") or 0):
        await expire_op_if_stale(uid, row)

    if await get_setting("bot_usage_requires_fresh_op", "1") != "1":
        return True

    allowed, text, markup = await process_op(user, message.chat.id)
    if allowed:
        await _remember_op_gate_ok(uid, "usage")
        return True
    await animated_answer(message, text or await get_setting("op_text"), reply_markup=markup)
    return False


async def ensure_fresh_op_for_usage_callback(callback: CallbackQuery) -> bool:
    """Gate ordinary inline buttons when OP is missing or older than the configured interval."""
    message = callback.message
    if not message:
        await callback.answer("Сначала пройдите ОП", show_alert=True)
        return False

    uid = int(callback.from_user.id)
    if _op_gate_cache_ok(uid, "usage"):
        return True

    interval = max(1, await get_int_setting("op_recheck_interval_minutes", 30))
    row = await get_user(uid)
    if is_op_fresh(row, interval):
        await _remember_op_gate_ok(uid, "usage")
        return True

    if row and int(row.get("is_op_passed") or 0):
        await expire_op_if_stale(uid, row)

    if await get_setting("bot_usage_requires_fresh_op", "1") != "1":
        return True

    await callback.answer("Сначала пройдите обязательную подписку", show_alert=True)
    allowed, text, markup = await process_op(callback.from_user, message.chat.id)
    if allowed:
        await _remember_op_gate_ok(uid, "usage")
        return True
    await safe_edit_or_answer(message, text or await get_setting("op_text"), reply_markup=markup, parse_mode=ParseMode.HTML)
    return False

async def withdraw_referrals_required(row: dict[str, Any] | None) -> tuple[bool, int, int]:
    try:
        have = int((row or {}).get("invited_count") or 0)
    except Exception:
        have = 0
    need = max(0, await get_int_setting("withdraw_min_referrals", 0))
    return have >= need, have, need


def withdraw_referrals_required_text(have: int, need: int) -> str:
    return (
        f"{ce('lock', '🔒')} <b>Вывод пока недоступен</b>\n\n"
        f"Для вывода нужно минимум <b>{need}</b> рефералов.\n"
        f"Сейчас засчитано: <b>{have}</b>.\n\n"
        "<i>Засчитываются только приглашённые пользователи, которые прошли ОП.</i>"
    )


async def ensure_withdraw_referrals_message(message: Message, row: dict[str, Any] | None = None) -> bool:
    row = row or await get_user(message.from_user.id)
    ok, have, need = await withdraw_referrals_required(row)
    if ok:
        return True
    await animated_answer(message, withdraw_referrals_required_text(have, need), parse_mode=ParseMode.HTML)
    return False


async def ensure_withdraw_referrals_callback(callback: CallbackQuery, row: dict[str, Any] | None = None) -> bool:
    row = row or await get_user(callback.from_user.id)
    ok, have, need = await withdraw_referrals_required(row)
    if ok:
        return True
    await callback.answer(f"Нужно рефералов: {need}. Сейчас: {have}.", show_alert=True)
    if callback.message:
        await animated_answer(callback.message, withdraw_referrals_required_text(have, need), parse_mode=ParseMode.HTML)
    return False


async def log_op(user_id: int, service: str, status: str, response: Any) -> None:
    row = await get_user(user_id)
    source_code = row["source_code"] if row else None
    async with await db() as conn:
        await conn.execute(
            "INSERT INTO op_logs(user_id,source_code,service,status,response_json,created_at) VALUES(?,?,?,?,?,?)",
            (user_id, source_code, service, status, json.dumps(response, ensure_ascii=False)[:5000], now_iso()),
        )
        await conn.commit()


async def save_op_session(user_id: int, provider: str, links: list[str], response: Any = None, status: str = "pending") -> None:
    cleaned_links = [str(x).strip() for x in links if str(x or "").strip()]
    async with await db() as conn:
        await conn.execute(
            "INSERT INTO op_sessions(user_id,provider,links_json,response_json,status,updated_at) VALUES(?,?,?,?,?,?) "
            "ON CONFLICT(user_id) DO UPDATE SET provider=excluded.provider, links_json=excluded.links_json, response_json=excluded.response_json, status=excluded.status, updated_at=excluded.updated_at",
            (
                int(user_id),
                provider,
                json.dumps(cleaned_links, ensure_ascii=False),
                compact_json(response, 5000) if response is not None else None,
                status,
                now_iso(),
            ),
        )
        await conn.commit()


async def get_op_session(user_id: int, provider: str | None = None) -> dict[str, Any] | None:
    async with await db() as conn:
        if provider:
            cur = await conn.execute("SELECT * FROM op_sessions WHERE user_id=? AND provider=?", (int(user_id), provider))
        else:
            cur = await conn.execute("SELECT * FROM op_sessions WHERE user_id=?", (int(user_id),))
        row = await cur.fetchone()
    if not row:
        return None
    data = dict(row)
    try:
        data["links"] = json.loads(data.get("links_json") or "[]")
    except Exception:
        data["links"] = []
    try:
        data["response"] = json.loads(data.get("response_json") or "{}") if data.get("response_json") else {}
    except Exception:
        data["response"] = {"raw": data.get("response_json")}
    return data


async def clear_op_session(user_id: int, provider: str | None = None) -> None:
    async with await db() as conn:
        if provider:
            await conn.execute("DELETE FROM op_sessions WHERE user_id=? AND provider=?", (int(user_id), provider))
        else:
            await conn.execute("DELETE FROM op_sessions WHERE user_id=?", (int(user_id),))
        await conn.commit()


async def subgram_request(user: Any, chat_id: int, *, event: str = "request") -> dict | None:
    api_key = await get_setting("subgram_api_key")
    user_id = int(getattr(user, "id", 0) or 0)
    if not api_key or await get_setting("subgram_enabled") != "1":
        data = {"status": "ok", "message": "SubGram disabled or token missing"}
        await log_provider_event("subgram", event, user_id=user_id or None, chat_id=chat_id, status="disabled", response=data)
        return data
    payload = {
        "user_id": user.id,
        "chat_id": chat_id,
        "first_name": user.first_name,
        "username": user.username,
        "language_code": user.language_code,
        "is_premium": bool(getattr(user, "is_premium", False)),
        "action": await get_setting("subgram_action", "subscribe"),
        "max_sponsors": int(await get_setting("subgram_max_sponsors", "5")),
        "get_links": int(await get_setting("subgram_get_links", "1")),
    }
    started = time.monotonic()
    http_status: int | None = None
    try:
        async with await http_session_context() as session:
            async with session.post(
                "https://api.subgram.org/get-sponsors",
                headers={"Auth": api_key, "Content-Type": "application/json"},
                json=payload,
                timeout=15,
            ) as resp:
                http_status = resp.status
                try:
                    data = await resp.json(content_type=None)
                except Exception:
                    raw_text = await resp.text()
                    data = {"status": "error", "message": "invalid_json", "raw": raw_text[:1200]}
    except Exception as e:
        elapsed = int((time.monotonic() - started) * 1000)
        await log_provider_event(
            "subgram",
            event,
            user_id=user_id or None,
            chat_id=chat_id,
            status="error",
            http_status=http_status,
            duration_ms=elapsed,
            request={**payload, "Auth": "***"},
            error=e,
        )
        log.warning("SubGram error: %s", e)
        return {"status": "error", "message": str(e)}

    elapsed = int((time.monotonic() - started) * 1000)
    status_value = str(data.get("status", "ok") if isinstance(data, dict) else "ok")
    log_status = "warning" if status_value == "warning" else ("error" if status_value in {"error", "fail", "failed"} else "ok")
    await log_provider_event(
        "subgram",
        event,
        user_id=user_id or None,
        chat_id=chat_id,
        status=log_status,
        http_status=http_status,
        duration_ms=elapsed,
        request={**payload, "Auth": "***"},
        response=data,
    )
    return data if isinstance(data, dict) else {"status": "ok", "response": data}


async def process_op(user: Any, chat_id: int) -> tuple[bool, str | None, InlineKeyboardMarkup | None]:
    provider = await choose_provider_for_role("op", "op_provider", "auto")
    if not provider:
        await mark_op_passed(user.id)
        return True, None, None

    try:
        allowed, status, response, links = await get_op_status(provider, user, chat_id)
    except Exception as e:
        response = {"status": "error", "message": str(e), "provider": provider}
        await log_op(user.id, provider, "error", response)
        log.warning("OP provider %s error: %s", provider, e)
        rows = [[ibtn("Проверить ещё раз", callback_data="check_op", icon="verify")]]
        text = (
            f"{ce('info', 'ℹ')} <b>Проверка ОП временно недоступна</b>\n\n"
            "<i>Попробуйте нажать «Проверить ещё раз» через несколько секунд. "
            "Заявку на вывод можно создать только после успешной проверки ОП.</i>"
        )
        return False, text, InlineKeyboardMarkup(inline_keyboard=rows)

    await log_op(user.id, provider, status, response or {})

    if not allowed:
        rows = [[ibtn("Подписаться", url=link, icon="subscribe")] for link in links if link]
        rows.append([ibtn("Я выполнил", callback_data="check_op", icon="verify")])
        text = await get_setting("op_text")
        if not links:
            await log_provider_event(
                provider,
                "op_no_links",
                user_id=int(user.id),
                chat_id=int(chat_id),
                status="warning",
                response={"status": status, "summary": safe_response_summary(response), "response": response},
            )
            text = (
                f"{ce('lock', '🔒')} <b>Остался один шаг</b>\n\n"
                "<i>Список каналов временно не получен от сервиса обязательной подписки.</i>\n\n"
                "<blockquote>Нажмите «Я выполнил» ещё раз через несколько секунд. "
                "Если кнопки подписки не появляются, администратору нужно проверить токен/роль провайдера и последние логи ОП.</blockquote>"
            )
        return False, text, InlineKeyboardMarkup(inline_keyboard=rows)

    await mark_op_passed(user.id)
    return True, None, None


HIVIEWS_SEND_MESSAGE_URL = "https://hiviews.net/sendMessage"
START_AD_PROVIDER_OPTIONS = ("off", "botohub_views", "hiviews", "auto", "mix")
AD_LOG_PROVIDERS = ("botohub_views", "hiviews")


def normalize_start_ad_provider(value: str | None) -> str:
    value = str(value or "botohub_views").strip().lower()
    aliases = {
        "botohub": "botohub_views",
        "botohubviews": "botohub_views",
        "boto_views": "botohub_views",
        "hiwiews": "hiviews",
        "hiwievs": "hiviews",
        "hi_views": "hiviews",
        "hi": "hiviews",
        "none": "off",
        "disabled": "off",
        "0": "off",
    }
    value = aliases.get(value, value)
    return value if value in START_AD_PROVIDER_OPTIONS else "botohub_views"


async def botohub_views_has_token() -> bool:
    return bool((await get_setting("botohub_views_token", "")).strip() or (await get_setting("botohub_token", "")).strip())


async def hiviews_has_token() -> bool:
    return bool((await get_setting("hiviews_api_key", "")).strip())


async def start_ad_selected_provider() -> str:
    return normalize_start_ad_provider(await get_setting("start_ad_provider", "botohub_views"))


async def start_ad_candidate_order() -> list[str]:
    provider = await start_ad_selected_provider()
    if provider == "off" or await get_setting("start_ad_enabled", "1") != "1":
        return []
    if provider == "botohub_views":
        return ["botohub_views"]
    if provider == "hiviews":
        return ["hiviews"]
    candidates = ["hiviews", "botohub_views"]
    if provider == "mix":
        random.shuffle(candidates)
    return candidates


async def start_ad_attempt_planned() -> bool:
    return bool(await start_ad_candidate_order())


async def hiviews_send_start(message: Message, *, provider_mode: str | None = None) -> bool:
    """Send /start event to HiViews.

    HiViews documentation allows activation only in private messages and only
    in response to /start. The start handlers call the selected ad dispatcher
    before local start flow so HiViews remains the first external ad action.
    """
    chat = getattr(message, "chat", None)
    user = getattr(message, "from_user", None)
    text = str(getattr(message, "text", "") or "").strip()
    event = "sendMessage_start"

    if not chat or getattr(chat, "type", "private") != "private" or not user or not text.startswith("/start"):
        return False

    enabled = await get_setting("hiviews_enabled", "1") == "1" or await get_setting("hiwiews_enabled", "1") == "1"
    if not enabled:
        await log_provider_event(
            "hiviews",
            event,
            user_id=int(user.id),
            chat_id=int(chat.id),
            status="disabled",
            request={"reason": "hiviews_disabled", "provider_mode": provider_mode},
        )
        return False

    api_key = (await get_setting("hiviews_api_key", "")).strip()
    if not api_key:
        await log_provider_event(
            "hiviews",
            event,
            user_id=int(user.id),
            chat_id=int(chat.id),
            status="skip",
            request={"reason": "empty_api_key", "provider_mode": provider_mode},
        )
        return False

    payload = {
        "UserId": int(user.id),
        "MessageId": int(message.message_id),
        "UserFirstName": str(getattr(user, "first_name", "") or ""),
        "LanguageCode": str(getattr(user, "language_code", "") or ""),
        "StartPlace": True,
    }
    started = time.monotonic()
    http_status: int | None = None
    try:
        async with await http_session_context() as session:
            async with session.post(
                HIVIEWS_SEND_MESSAGE_URL,
                headers={"Authorization": api_key, "Content-Type": "application/json"},
                json=payload,
                timeout=15,
            ) as resp:
                http_status = int(resp.status)
                body = await resp.text(encoding="utf-8", errors="replace")
        try:
            response_data: Any = json.loads(body)
        except Exception:
            response_data = {"raw": body[:3000]}
        ok = 200 <= int(http_status or 0) < 300
        await log_provider_event(
            "hiviews",
            event,
            user_id=int(user.id),
            chat_id=int(chat.id),
            status="ok" if ok else "error",
            http_status=http_status,
            duration_ms=int((time.monotonic() - started) * 1000),
            request={**payload, "provider_mode": provider_mode},
            response=response_data,
        )
        await log_ad_impression(int(user.id), int(chat.id), "start:hiviews", {"provider": "hiviews", "ok": ok, "http_status": http_status, "response": response_data})
        if ok:
            log.info("HiViews /start event sent for %s", user.id)
        else:
            log.info("HiViews /start event failed for %s: HTTP %s %s", user.id, http_status, safe_response_summary(response_data))
        return bool(ok)
    except Exception as e:
        await log_provider_event(
            "hiviews",
            event,
            user_id=int(user.id),
            chat_id=int(chat.id),
            status="error",
            http_status=http_status,
            duration_ms=int((time.monotonic() - started) * 1000),
            request={**payload, "provider_mode": provider_mode},
            error=e,
        )
        log.warning("HiViews /start error for %s: %s", getattr(user, "id", "?"), e)
        return False


async def hiviews_start_delay(sent: bool) -> None:
    if not sent:
        return
    delay = await get_float_setting("hiviews_start_delay_seconds", 2.0)
    delay = max(0.0, min(float(delay), 10.0))
    if delay > 0:
        await asyncio.sleep(delay)


BOTOHUB_VIEWS_URL = "https://views.botohub.me/ad/SendPost"
BOTOHUB_VIEWS_CODES = {
    1: "Success",
    2: "RevokedTokenError",
    3: "UserForbiddenError",
    4: "ToManyRequestsError",
    5: "OtherBotApiError",
    6: "OtherError",
    7: "AdLimited",
    8: "NoAds",
    9: "BotIsNotEnabled",
    10: "Banned",
    11: "InReview",
}


async def botohub_views_send_post(chat_id: int, *, is_hi: bool = True, placement: str = "start") -> tuple[bool, dict]:
    """Send an advertising post through BotoHub Views and write provider logs."""
    placement = str(placement or "start")
    event = f"send_post_{placement}"
    payload = {"SendToChatId": int(chat_id), "hi": bool(is_hi)}
    started = time.monotonic()
    http_status: int | None = None

    if placement == "start" and await get_setting("start_ad_enabled", "1") != "1":
        data = {"SendPostResult": 0, "message": "start ad disabled"}
        await log_provider_event("botohub_views", event, user_id=int(chat_id), chat_id=int(chat_id), status="disabled", request=payload, response=data)
        return False, data
    if placement != "start" and await get_setting("botohub_views_regular_enabled", "1") != "1":
        data = {"SendPostResult": 0, "message": "regular ad disabled"}
        await log_provider_event("botohub_views", event, user_id=int(chat_id), chat_id=int(chat_id), status="disabled", request=payload, response=data)
        return False, data
    if await get_setting("botohub_views_enabled", "1") != "1":
        data = {"SendPostResult": 0, "message": "BotoHub Views disabled"}
        await log_provider_event("botohub_views", event, user_id=int(chat_id), chat_id=int(chat_id), status="disabled", request=payload, response=data)
        return False, data

    token = (await get_setting("botohub_views_token", "")).strip()
    if not token:
        # Compatibility fallback for users who temporarily placed the Views token into the old BotoHub field.
        token = (await get_setting("botohub_token", "")).strip()
    if not token:
        data = {"SendPostResult": 0, "message": "BotoHub Views token is empty"}
        await log_provider_event("botohub_views", event, user_id=int(chat_id), chat_id=int(chat_id), status="skip", request=payload, response=data)
        return False, data

    try:
        async with await http_session_context() as session:
            async with session.post(
                BOTOHUB_VIEWS_URL,
                headers={"Authorization": token, "Content-Type": "application/json"},
                json=payload,
                timeout=15,
            ) as resp:
                http_status = int(resp.status)
                data = await resp.json(content_type=None)
    except Exception as e:
        data = {"SendPostResult": 0, "message": str(e)}
        await log_provider_event(
            "botohub_views",
            event,
            user_id=int(chat_id),
            chat_id=int(chat_id),
            status="error",
            http_status=http_status,
            duration_ms=int((time.monotonic() - started) * 1000),
            request=payload,
            response=data,
            error=e,
        )
        return False, data

    result_code = int(data.get("SendPostResult") or 0) if isinstance(data, dict) else 0
    if isinstance(data, dict):
        data.setdefault("ResultName", BOTOHUB_VIEWS_CODES.get(result_code, "Unknown"))
        data.setdefault("http_status", http_status)
    result = data if isinstance(data, dict) else {"SendPostResult": result_code, "raw": str(data), "http_status": http_status}
    ok = result_code == 1
    await log_provider_event(
        "botohub_views",
        event,
        user_id=int(chat_id),
        chat_id=int(chat_id),
        status="ok" if ok else "empty" if result_code == 8 else "error",
        http_status=http_status,
        duration_ms=int((time.monotonic() - started) * 1000),
        request=payload,
        response=result,
    )
    return ok, result


async def is_new_user_for_start(user_id: int | None) -> bool:
    if not user_id:
        return True
    async with await db() as conn:
        cur = await conn.execute("SELECT 1 FROM users WHERE id=?", (int(user_id),))
        return await cur.fetchone() is None


async def send_start_ad(message: Message, user_id: int, *, is_new_user: bool | None = None) -> bool:
    """Selected /start ad dispatcher: HiViews, BotoHub Views, auto fallback or mix."""
    mode = await start_ad_selected_provider()
    candidates = await start_ad_candidate_order()
    if not candidates:
        await log_provider_event("start_ads", "select_start", user_id=int(user_id), chat_id=int(user_id), status="disabled", request={"mode": mode})
        return False

    for provider in candidates:
        if provider == "hiviews":
            ok = await hiviews_send_start(message, provider_mode=mode)
            if ok:
                await hiviews_start_delay(True)
                return True
            continue

        if provider == "botohub_views":
            if await get_setting("start_ad_only_new_users", "1") == "1":
                if is_new_user is None:
                    is_new_user = await is_new_user_for_start(user_id)
                if not is_new_user:
                    await log_provider_event(
                        "botohub_views",
                        "send_post_start",
                        user_id=int(user_id),
                        chat_id=int(user_id),
                        status="skip",
                        request={"reason": "not_new_user", "provider_mode": mode},
                    )
                    continue
            ok, data = await botohub_views_send_post(user_id, is_hi=True, placement="start")
            code = data.get("SendPostResult") if isinstance(data, dict) else None
            name = data.get("ResultName") if isinstance(data, dict) else None
            await log_ad_impression(user_id, user_id, "start:botohub_views", data if isinstance(data, dict) else {"raw": str(data)})
            if ok:
                log.info("BotoHub Views start ad sent to %s", user_id)
                return True
            log.info("BotoHub Views start ad skipped for %s: %s %s", user_id, code, name or data)
            continue

    await log_provider_event("start_ads", "select_start", user_id=int(user_id), chat_id=int(user_id), status="empty", request={"mode": mode, "candidates": candidates}, response={"sent": False})
    return False



REGULAR_AD_REASON_SETTING = {
    "menu": "botohub_views_after_menu_enabled",
    "task": "botohub_views_after_task_enabled",
    "bonus": "botohub_views_after_bonus_enabled",
    "game": "botohub_views_after_game_enabled",
    "withdraw": "botohub_views_after_withdraw_enabled",
}


async def log_ad_impression(user_id: int, chat_id: int, placement: str, data: dict) -> None:
    try:
        result_code = int(data.get("SendPostResult") or 0) if isinstance(data, dict) else 0
        if str(placement) == "regular":
            _AD_LAST_CACHE[int(user_id)] = time.monotonic()
        async with await db() as conn:
            await conn.execute(
                "INSERT INTO ad_impression_logs(user_id,chat_id,placement,result_code,response_json,created_at) VALUES(?,?,?,?,?,?)",
                (int(user_id), int(chat_id), str(placement), result_code, json.dumps(data, ensure_ascii=False)[:3000], now_iso()),
            )
            await conn.commit()
    except Exception as e:
        log.debug("ad impression log skipped: %s", e)


async def regular_ad_cooldown_passed(user_id: int) -> bool:
    cooldown = max(0, await get_int_setting("botohub_views_regular_cooldown_minutes", 10))
    if cooldown <= 0:
        return True
    uid = int(user_id)
    now_mono = time.monotonic()
    last_mono = _AD_LAST_CACHE.get(uid)
    if last_mono is not None:
        return now_mono - last_mono >= cooldown * 60
    async with await db() as conn:
        cur = await conn.execute(
            "SELECT created_at FROM ad_impression_logs WHERE user_id=? AND placement='regular' ORDER BY id DESC LIMIT 1",
            (uid,),
        )
        row = await cur.fetchone()
    last_dt = parse_dt(row["created_at"] if row else None)
    if not last_dt:
        return True
    passed = datetime.now(timezone.utc) - last_dt >= timedelta(minutes=cooldown)
    if not passed:
        elapsed = (datetime.now(timezone.utc) - last_dt).total_seconds()
        _AD_LAST_CACHE[uid] = now_mono - max(0, elapsed)
    return passed


async def maybe_send_regular_ad(message: Message, user_id: int | None = None, *, reason: str = "menu") -> bool:
    """Show BotoHub Views not only on /start: menu, tasks, bonus, games, withdraw.

    Uses hi=False and a per-user cooldown/chance so ads do not flood the chat.
    """
    if await get_setting("botohub_views_regular_enabled", "1") != "1":
        return False
    reason = str(reason or "menu")
    reason_key = REGULAR_AD_REASON_SETTING.get(reason, "botohub_views_after_menu_enabled")
    if await get_setting(reason_key, "1") != "1":
        return False
    chat = getattr(message, "chat", None)
    if not chat or getattr(chat, "type", "private") != "private":
        return False
    uid = int(user_id or getattr(chat, "id", 0) or 0)
    if not uid:
        return False
    if not await regular_ad_cooldown_passed(uid):
        return False
    chance = max(0, min(await get_int_setting("botohub_views_regular_chance_percent", 35), 100))
    if chance <= 0 or random.randint(1, 100) > chance:
        return False
    ok, data = await botohub_views_send_post(int(chat.id), is_hi=False, placement="regular")
    await log_ad_impression(uid, int(chat.id), "regular", data if isinstance(data, dict) else {"raw": str(data)})
    if ok:
        log.info("BotoHub Views regular ad sent to %s after %s", uid, reason)
    else:
        log.debug("BotoHub Views regular ad skipped for %s after %s: %s", uid, reason, data)
    return bool(ok)


async def _safe_maybe_regular_ad(message: Message, user_id: int | None = None, *, reason: str = "menu") -> None:
    try:
        await maybe_send_regular_ad(message, user_id, reason=reason)
    except Exception as e:
        log.debug("regular ad task skipped: %s", e)


def schedule_maybe_regular_ad(message: Message, user_id: int | None = None, *, reason: str = "menu") -> None:
    """Run regular BotoHub Views after the user-facing answer without blocking the bot response."""
    try:
        asyncio.create_task(_safe_maybe_regular_ad(message, user_id, reason=reason))
    except RuntimeError:
        # No running loop, should not happen inside aiogram handlers. Fallback: silently skip ad.
        log.debug("regular ad schedule skipped: no running event loop")


async def send_start_sequence(message: Message, user_id: int | None = None, skip_ad: bool = False, is_new_user: bool = False, user: Any | None = None, ad_already_attempted: bool = False) -> None:
    sequence_user = user or getattr(message, "from_user", None)
    if user_id is None and sequence_user:
        user_id = sequence_user.id

    if await get_setting("cleanup_start_messages_enabled", "0") == "1" and user_id is not None:
        await cleanup_bot_messages(message, user_id, scopes=["start", "task_header", "task", "task_status", "general", "menu"])

    if await get_setting("start_sequence_enabled", "1") != "1":
        await send_main(message, user_id)
        return

    if skip_ad:
        ad_sent = True
    elif ad_already_attempted:
        ad_sent = False
    elif user_id is not None:
        ad_sent = await send_start_ad(message, user_id, is_new_user=is_new_user)
    else:
        ad_sent = False

    # Если рекламный показ не вернул ссылку, всё равно отправляем приветствие, чтобы старт не выглядел пустым.
    if not ad_sent:
        await animated_answer(message, await get_setting("start_text"), reply_markup=await main_menu(user_id), track_scope="start", track_user_id=user_id)
        await asyncio.sleep(0.15)

    if await get_setting("start_show_bonus_block", "1") == "1":
        await animated_answer(
            message,
            await get_setting("start_bonus_text", str(DEFAULT_SETTINGS.get("start_bonus_text", ""))),
            reply_markup=await main_menu(user_id),
            track_scope="start",
            track_user_id=user_id,
        )
        await asyncio.sleep(0.15)

    if await get_setting("start_show_tasks_after_bonus", "1") == "1":
        if user_id is not None:
            await cleanup_task_flow(message, user_id)
        await animated_answer(message, await get_setting("tasks_top_text"), track_scope="task_header", track_user_id=user_id)
        await asyncio.sleep(0.15)
        await issue_task(message, skip=False, user=sequence_user, chat_id=getattr(getattr(message, "chat", None), "id", None), cleanup_before=False)


@router.message(CommandStart(deep_link=True))
async def start_deep(message: Message, command: CommandStart) -> None:
    pre_ad_sent = False
    pre_ad_attempted = False
    if message.from_user and await get_setting("start_ad_before_op_enabled", "1") == "1":
        # This is intentionally at the top of /start. If HiViews is selected,
        # its request stays the first ad action required by the service rules.
        pre_ad_attempted = await start_ad_attempt_planned()
        pre_ad_sent = await send_start_ad(message, message.from_user.id, is_new_user=None)
    code = command.args
    check_code = parse_reward_check_payload(code)
    new_user = await is_new_user_for_start(message.from_user.id if message.from_user else None)
    # Чек не записываем как UTM/source_code, чтобы он не загрязнял статистику источников.
    await upsert_user(message, None if check_code else code)
    allowed, text, markup = await process_op(message.from_user, message.chat.id)
    if not allowed:
        if check_code and message.from_user:
            await store_pending_reward_check(message.from_user.id, check_code)
            text = (text or await get_setting("op_text")) + "\n\n<blockquote>После прохождения ОП чек активируется автоматически.</blockquote>"
        await animated_answer(message, text, reply_markup=markup)
        return
    if check_code and message.from_user:
        _, activation_text = await activate_reward_check(message.from_user.id, check_code)
        await animated_answer(message, activation_text, track_scope="menu", track_user_id=message.from_user.id)
    await send_start_sequence(message, skip_ad=pre_ad_sent, is_new_user=new_user, user=message.from_user, ad_already_attempted=pre_ad_attempted)


@router.message(CommandStart())
async def start(message: Message) -> None:
    pre_ad_sent = False
    pre_ad_attempted = False
    if message.from_user and await get_setting("start_ad_before_op_enabled", "1") == "1":
        # This is intentionally at the top of /start. If HiViews is selected,
        # its request stays the first ad action required by the service rules.
        pre_ad_attempted = await start_ad_attempt_planned()
        pre_ad_sent = await send_start_ad(message, message.from_user.id, is_new_user=None)
    new_user = await is_new_user_for_start(message.from_user.id if message.from_user else None)
    await upsert_user(message, None)
    allowed, text, markup = await process_op(message.from_user, message.chat.id)
    if not allowed:
        await animated_answer(message, text, reply_markup=markup)
        return
    await send_start_sequence(message, skip_ad=pre_ad_sent, is_new_user=new_user, user=message.from_user, ad_already_attempted=pre_ad_attempted)


@router.callback_query(F.data == "check_op")
async def check_op_callback(callback: CallbackQuery) -> None:
    await callback.answer("⏳ Проверяем подписки...")
    if not callback.message:
        await callback.answer("Откройте бота заново через /start", show_alert=True)
        return
    allowed, text, markup = await process_op(callback.from_user, callback.message.chat.id)
    if not allowed:
        await safe_edit_or_answer(callback.message, text, reply_markup=markup, parse_mode=ParseMode.HTML)
        return
    try:
        await callback.message.delete()
    except TelegramBadRequest:
        pass
    pending_check_text = await consume_pending_reward_check(callback.from_user.id)
    if pending_check_text:
        await animated_answer(callback.message, pending_check_text, track_scope="menu", track_user_id=callback.from_user.id)
    else:
        await animated_answer(callback.message, f"{ce('check', '✅')} <b>Готово!</b>\n\n<i>Доступ открыт — можно пользоваться ботом.</i>")
    await send_start_sequence(callback.message, callback.from_user.id, skip_ad=True, user=callback.from_user)


@router.message(F.text.in_({"Заработать звёзды", "⭐ Заработать звёзды"}))
async def earn(message: Message, bot: Bot) -> None:
    await cleanup_general_flow(message, message.from_user.id if message.from_user else None)
    await upsert_user(message)
    me = await bot.get_me()
    row = await get_user(message.from_user.id)
    ref_link = f"https://t.me/{me.username}?start=ref_{message.from_user.id}"
    text = (await get_setting("earn_text")).format(
        ref_reward=fmt_amount(await get_float_setting("ref_reward", 4.5)),
        ref_link=ref_link,
        invited=row["invited_count"] if row else 0,
    )
    await animated_answer(message, text)
    schedule_maybe_regular_ad(message, message.from_user.id if message.from_user else None, reason="menu")



def resolve_chat_id_value(value: str) -> int | str:
    value = str(value or "").strip()
    if value.startswith("-") and value[1:].isdigit():
        return int(value)
    if value.isdigit():
        return int(value)
    return value


def withdraw_status_title(status: str) -> str:
    return {
        "pending": "Ожидает обработки ⚙️",
        "approved": "Отправлено ✅",
        "declined": "Отклонено ❌",
    }.get(str(status or "pending"), str(status or "pending"))


def payout_gift_for_amount(amount: float) -> str:
    gift = payout_gift_by_amount(amount)
    return payout_gift_icon(gift)


async def get_withdraw_request_full(request_id: int | str) -> Optional[aiosqlite.Row]:
    async with await db() as conn:
        cur = await conn.execute(
            """
            SELECT w.*, u.username, u.first_name, u.balance, u.created_at AS user_created_at
            FROM withdraw_requests w
            LEFT JOIN users u ON u.id=w.user_id
            WHERE w.id=?
            """,
            (int(request_id),),
        )
        return await cur.fetchone()


async def payout_channel_message_text(request_id: int | str) -> str:
    req = await get_withdraw_request_full(request_id)
    if not req:
        return f"{ce('cross', '❌')} <b>Заявка не найдена</b>"
    title = await get_setting("payout_channel_title", "MrKrab Stars | Выплаты")
    amount = float(req["amount"] or 0)
    selected_gift = payout_gift_by_id(req["gift_id"] if "gift_id" in req.keys() else None) or payout_gift_by_amount(amount)
    username = req["username"] or ""
    first_name = req["first_name"] or "Пользователь"
    user_label = f"@{html.escape(username)}" if username else html.escape(first_name)
    status = str(req["status"] or "pending")
    status_icon = "loading" if status == "pending" else ("check" if status == "approved" else "cross")
    lines = [
        f"<b>{html.escape(title)}</b>",
        f"{ce('check', '✅')} <b>Запрос на вывод №{int(req['id'])}</b>",
        "",
        f"{ce('profile', '👤')} <b>Пользователь:</b> {user_label} | ID <code>{int(req['user_id'])}</code>",
        f"{ce('gift', '🎁')} <b>Количество:</b> {star_amount(amount)} [{payout_gift_label(selected_gift)}]",
        "",
        f"{ce(status_icon, '🔄' if status == 'pending' else ('✅' if status == 'approved' else '❌'))} <b>Статус:</b> <b>{withdraw_status_title(status)}</b>",
    ]
    if req["processed_by"]:
        lines.append(f"<i>Обработал админ:</i> <code>{int(req['processed_by'])}</code>")
    if req["updated_at"]:
        lines.append(f"<i>Обновлено:</i> <code>{html.escape(str(req['updated_at']))}</code>")
    return "\n".join(lines)


async def payout_channel_keyboard(request_id: int | str, status: str = "pending") -> InlineKeyboardMarkup | None:
    rows = []
    if status == "pending":
        rows.append([
            ibtn("Отправить", callback_data=f"wdch:ok:{int(request_id)}", icon="check"),
            ibtn("Отклонить", callback_data=f"wdch:no:{int(request_id)}", icon="cross"),
        ])
    if await get_setting("payout_channel_profile_button_enabled", "1") == "1":
        rows.append([ibtn("Профиль", callback_data=f"wdch:profile:{int(request_id)}", icon="profile")])
    return InlineKeyboardMarkup(inline_keyboard=rows) if rows else None


async def send_payout_channel_notification(bot: Bot, request_id: int | str) -> bool:
    if await get_setting("payout_channel_enabled", "0") != "1":
        return False
    channel_id = (await get_setting("payout_channel_chat_id", "")).strip()
    if not channel_id:
        log.info("Payout channel is enabled but payout_channel_chat_id is empty")
        return False
    req = await get_withdraw_request_full(request_id)
    if not req:
        return False
    try:
        msg = await bot.send_message(
            chat_id=resolve_chat_id_value(channel_id),
            text=await payout_channel_message_text(request_id),
            reply_markup=await payout_channel_keyboard(request_id, str(req["status"] or "pending")),
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
        )
        async with await db() as conn:
            await conn.execute(
                "UPDATE withdraw_requests SET payout_channel_chat_id=?, payout_channel_message_id=? WHERE id=?",
                (str(channel_id), int(msg.message_id), int(request_id)),
            )
            await conn.commit()
        return True
    except Exception as e:
        log.warning("Payout channel notification failed: %s", e)
        return False


async def update_payout_channel_message(bot: Bot, request_id: int | str) -> bool:
    req = await get_withdraw_request_full(request_id)
    if not req:
        return False
    channel_id = req["payout_channel_chat_id"] or await get_setting("payout_channel_chat_id", "")
    message_id = req["payout_channel_message_id"]
    if not channel_id or not message_id:
        return False
    try:
        await bot.edit_message_text(
            chat_id=resolve_chat_id_value(str(channel_id)),
            message_id=int(message_id),
            text=await payout_channel_message_text(request_id),
            reply_markup=await payout_channel_keyboard(request_id, str(req["status"] or "pending")),
            parse_mode=ParseMode.HTML,
            disable_web_page_preview=True,
        )
        return True
    except TelegramBadRequest as e:
        log.debug("Payout channel edit skipped: %s", e)
        return False
    except Exception as e:
        log.warning("Payout channel edit failed: %s", e)
        return False


async def notify_user_withdraw_status(bot: Bot, request_id: int | str) -> None:
    if await get_setting("payout_channel_notify_user", "1") != "1":
        return
    req = await get_withdraw_request_full(request_id)
    if not req:
        return
    status = str(req["status"] or "pending")
    if status == "approved":
        text = f"{ce('check', '✅')} <b>Вывод отправлен</b>\n\n<i>Заявка №{int(req['id'])} на {fmt_amount(float(req['amount']))}⭐ обработана.</i>"
    elif status == "declined":
        text = f"{ce('cross', '❌')} <b>Вывод отклонён</b>\n\n<i>Заявка №{int(req['id'])} на {fmt_amount(float(req['amount']))}⭐ отклонена. Звёзды возвращены на баланс.</i>"
    else:
        return
    try:
        await bot.send_message(int(req["user_id"]), render_bot_text(text), parse_mode=ParseMode.HTML)
    except Exception as e:
        log.debug("withdraw user notify skipped: %s", e)


async def process_withdraw_request(request_id: int | str, action: str, admin_id: int, bot: Bot | None = None) -> tuple[bool, str]:
    status = "approved" if action == "ok" else "declined"
    async with await db() as conn:
        cur = await conn.execute("SELECT * FROM withdraw_requests WHERE id=? AND status='pending'", (int(request_id),))
        req = await cur.fetchone()
        if not req:
            return False, "Заявка не найдена или уже обработана"
        if status == "declined":
            await conn.execute("UPDATE users SET balance=balance+? WHERE id=?", (float(req["amount"]), int(req["user_id"])))
        await conn.execute(
            "UPDATE withdraw_requests SET status=?, updated_at=?, processed_by=? WHERE id=?",
            (status, now_iso(), int(admin_id), int(request_id)),
        )
        await conn.commit()
    if bot:
        await update_payout_channel_message(bot, request_id)
        await notify_user_withdraw_status(bot, request_id)
    return True, status


def withdraw_gift_callback_data(amount: float | str, gift_id: str | None = None) -> str:
    amount_text = fmt_amount(float(amount))
    if gift_id:
        return f"withdraw:{amount_text}:{gift_id}"
    return f"withdraw:{amount_text}"


def parse_withdraw_callback(data: str) -> tuple[float, dict[str, Any] | None]:
    parts = str(data or "").split(":")
    if len(parts) < 2:
        raise ValueError("invalid withdraw callback")
    amount = float(parts[1].replace(",", "."))
    if amount <= 0:
        raise ValueError("withdraw amount must be positive")
    gift = payout_gift_by_id(parts[2]) if len(parts) >= 3 else None
    if gift is not None:
        # Trust the configured gift price, not a user-crafted callback amount.
        amount = float(gift.get("amount") or amount)
    elif len(parts) >= 3:
        gift = {"amount": amount, "name": "Подарок", "gift_id": parts[2], "emoji": "🎁", "icon": parts[2]}
    return amount, gift


def withdraw_gift_buttons() -> list[list[InlineKeyboardButton]]:
    rows: list[list[InlineKeyboardButton]] = []
    line: list[InlineKeyboardButton] = []
    for gift in STANDARD_PAYOUT_GIFTS:
        amount = float(gift["amount"])
        line.append(
            ibtn(
                f"{fmt_amount(amount)} | {gift['name']}",
                callback_data=withdraw_gift_callback_data(amount, str(gift["gift_id"])),
                icon=str(gift["gift_id"]),
            )
        )
        if len(line) == 2:
            rows.append(line)
            line = []
    if line:
        rows.append(line)
    return rows


@router.message(F.text.in_({"Вывести звёзды", "🎁 Вывести звёзды"}))
async def withdraw_menu(message: Message) -> None:
    await cleanup_general_flow(message, message.from_user.id if message.from_user else None)
    if not await ensure_fresh_op_for_withdraw(message):
        return
    row = await get_user(message.from_user.id)
    if not await ensure_withdraw_referrals_message(message, row):
        return
    balance = float(row["balance"] if row else 0)
    rows: list[list[InlineKeyboardButton]] = []
    if await get_setting("withdraw_gifts_enabled", "1") == "1":
        rows = withdraw_gift_buttons()
    else:
        amounts = [x.strip() for x in (await get_setting("withdraw_amounts")).split(",") if x.strip()]
        line: list[InlineKeyboardButton] = []
        for a in amounts:
            line.append(ibtn(f"{a}", callback_data=withdraw_gift_callback_data(a), icon="star"))
            if len(line) == 2:
                rows.append(line)
                line = []
        if line:
            rows.append(line)
    await animated_answer(message, (await get_setting("withdraw_text")).format(balance=fmt_amount(balance)), reply_markup=InlineKeyboardMarkup(inline_keyboard=rows))
    schedule_maybe_regular_ad(message, message.from_user.id if message.from_user else None, reason="withdraw")


@router.callback_query(F.data.startswith("withdraw:"))
async def withdraw_create(callback: CallbackQuery) -> None:
    if not await ensure_fresh_op_for_withdraw_callback(callback):
        return
    try:
        amount, gift = parse_withdraw_callback(callback.data)
    except Exception:
        await callback.answer("Некорректная сумма вывода", show_alert=True)
        return
    row = await get_user(callback.from_user.id)
    if not await ensure_withdraw_referrals_callback(callback, row):
        return
    balance = float(row["balance"] if row else 0)
    if balance < amount:
        await callback.answer("Недостаточно звёзд", show_alert=True)
        await animated_answer(callback.message, (await get_setting("withdraw_low_balance")).format(amount=fmt_amount(amount), balance=fmt_amount(balance)))
        return
    gift_id = str(gift.get("gift_id")) if gift else None
    gift_name = str(gift.get("name")) if gift else None
    async with await db() as conn:
        # Atomic balance reservation: protects from double-clicks and concurrent old callbacks.
        cur_update = await conn.execute(
            "UPDATE users SET balance=balance-? WHERE id=? AND balance>=?",
            (amount, callback.from_user.id, amount),
        )
        if cur_update.rowcount != 1:
            cur_balance = await conn.execute("SELECT balance FROM users WHERE id=?", (callback.from_user.id,))
            balance_row = await cur_balance.fetchone()
            current_balance = float(balance_row["balance"] if balance_row else 0)
            await conn.commit()
            invalidate_user_cache(callback.from_user.id)
            await callback.answer("Недостаточно звёзд", show_alert=True)
            await animated_answer(callback.message, (await get_setting("withdraw_low_balance")).format(amount=fmt_amount(amount), balance=fmt_amount(current_balance)))
            return
        cur = await conn.execute(
            "INSERT INTO withdraw_requests(user_id,amount,status,created_at,updated_at,gift_id,gift_name) VALUES(?,?,?,?,?,?,?)",
            (callback.from_user.id, amount, "pending", now_iso(), now_iso(), gift_id, gift_name),
        )
        request_id = int(cur.lastrowid)
        await conn.commit()
    invalidate_user_cache(callback.from_user.id)
    await send_payout_channel_notification(callback.message.bot, request_id)
    created_text = (await get_setting("withdraw_created")).format(amount=fmt_amount(amount))
    if gift:
        created_text += f"\n\n<b>Подарок:</b> {payout_gift_label(gift)}"
    await animated_answer(callback.message, created_text)
    schedule_maybe_regular_ad(callback.message, callback.from_user.id, reason="withdraw")
    await callback.answer("Заявка создана")


async def piarflow_get_task(user_id: int, chat_id: int, *, event: str = "get_task") -> tuple[str | None, float, dict]:
    api_key = await get_setting("piarflow_api_key")
    if not api_key or await get_setting("piarflow_enabled") != "1":
        data = {"error": "PiarFlow disabled or token missing"}
        await log_provider_event("piarflow", event, user_id=user_id, chat_id=chat_id, status="disabled", response=data)
        return None, 0, data

    max_sponsors = max(1, min(await get_int_setting("piarflow_max_sponsors", 5), 20))
    payload = {"user_id": int(user_id), "chat_id": int(chat_id), "max_sponsors": max_sponsors}
    started = time.monotonic()
    http_status: int | None = None
    try:
        async with await http_session_context() as session:
            async with session.post(
                "https://piarflow.ru/v1/sponsors",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json=payload,
                timeout=15,
            ) as resp:
                http_status = resp.status
                try:
                    data = await resp.json(content_type=None)
                except Exception:
                    raw_text = await resp.text()
                    data = {"error": "invalid_json", "raw": raw_text[:1200]}
    except Exception as e:
        elapsed = int((time.monotonic() - started) * 1000)
        await log_provider_event("piarflow", event, user_id=user_id, chat_id=chat_id, status="error", duration_ms=elapsed, request=payload, error=e)
        raise

    elapsed = int((time.monotonic() - started) * 1000)
    sponsors = data.get("sponsors", []) if isinstance(data, dict) else []
    if isinstance(sponsors, dict):
        sponsors = list(sponsors.values())
    sponsors = sponsors or []
    link = None
    api_reward: float | None = None
    for sponsor in sponsors:
        if not isinstance(sponsor, dict):
            continue
        candidate = sponsor.get("link") or sponsor.get("url") or sponsor.get("channel_link") or sponsor.get("invite_link")
        if candidate:
            link = str(candidate)
            try:
                api_reward = float(sponsor.get("price") or sponsor.get("reward") or 0)
            except Exception:
                api_reward = None
            break
    reward = await fixed_task_reward("piarflow", api_reward)
    status = "ok" if link else "empty"
    await log_provider_event(
        "piarflow",
        event,
        user_id=user_id,
        chat_id=chat_id,
        status=status,
        http_status=http_status,
        duration_ms=elapsed,
        request={**payload, "api_key": "***"},
        response=data,
    )
    return link, reward if link else 0, data if isinstance(data, dict) else {"response": data}


PiarflowSuccessStatuses = {"subscribed", "subscribe", "done", "completed", "complete", "success", "true", "1", "yes"}
PiarflowFailStatuses = {"not_subscribed", "unsubscribed", "not_counted", "pending", "wait", "waiting", "false", "0", "no", "fail", "failed"}


def normalize_link_for_compare(value: str) -> str:
    value = str(value or "").strip()
    value = value.replace("http://", "https://")
    value = value.rstrip("/")
    return value


def piarflow_response_sponsors(data: Any) -> list[dict[str, Any]]:
    if not isinstance(data, dict):
        return []
    sponsors = data.get("sponsors", []) or data.get("result", []) or data.get("data", []) or []
    if isinstance(sponsors, dict):
        sponsors = list(sponsors.values())
    return [s for s in sponsors if isinstance(s, dict)]


def piarflow_sponsor_status(sponsor: dict[str, Any]) -> tuple[bool | None, str]:
    raw_status = sponsor.get("status") or sponsor.get("state")
    status = str(raw_status or "").strip().lower()
    for key in ("subscribed", "is_subscribed", "completed", "done", "success"):
        if isinstance(sponsor.get(key), bool):
            return bool(sponsor.get(key)), f"{key}={sponsor.get(key)}"
    if status in PiarflowSuccessStatuses:
        return True, f"status={status}"
    if status in PiarflowFailStatuses:
        return False, f"status={status}"
    return None, f"status={status or 'нет'}"


def piarflow_check_result_from_response(data: dict, link: str) -> tuple[bool, str]:
    ok, reason, _pending = piarflow_check_many_result_from_response(data, [link])
    return ok, reason


def piarflow_check_many_result_from_response(data: dict, links: list[str]) -> tuple[bool, str, list[str]]:
    if not isinstance(data, dict):
        return False, "Ответ API не является JSON-объектом", links

    requested = [str(x).strip() for x in links if str(x or "").strip()]
    if not requested:
        return False, "Нет ссылок для проверки", []

    sponsors = piarflow_response_sponsors(data)
    if not sponsors:
        # В PiarFlow верхний status='ok' означает только успешный API-запрос, а не подписку.
        # Поэтому без sponsors нельзя считать ОП/задание выполненным.
        for key in ("ok", "success", "completed", "result", "subscribed"):
            if key in data and isinstance(data.get(key), bool):
                result = bool(data.get(key))
                return result, f"верхнее поле {key}={data.get(key)}, sponsors отсутствуют", [] if result else requested
        return False, f"sponsors отсутствуют, верхний status={data.get('status', 'нет')}", requested

    by_link: dict[str, dict[str, Any]] = {}
    for sponsor in sponsors:
        sponsor_link = sponsor.get("link") or sponsor.get("url") or sponsor.get("channel_link") or sponsor.get("invite_link")
        if sponsor_link:
            by_link[normalize_link_for_compare(str(sponsor_link))] = sponsor

    pending: list[str] = []
    details: list[str] = []
    for requested_link in requested:
        normalized = normalize_link_for_compare(requested_link)
        sponsor = by_link.get(normalized)
        if sponsor is None and len(requested) == 1 and len(sponsors) == 1:
            sponsor = sponsors[0]
        if sponsor is None:
            pending.append(requested_link)
            details.append(f"{requested_link}: не найден в ответе")
            continue
        is_ok, status_text = piarflow_sponsor_status(sponsor)
        details.append(f"{requested_link}: {status_text}")
        if is_ok is not True:
            pending.append(requested_link)

    if not pending:
        return True, "все ссылки выполнены; " + "; ".join(details[:5]), []
    return False, f"не выполнено {len(pending)}/{len(requested)}; " + "; ".join(details[:5]), pending


async def piarflow_check_links(user_id: int, links: list[str], chat_id: int | None = None, *, event: str = "check_task") -> tuple[bool, dict, list[str]]:
    api_key = await get_setting("piarflow_api_key")
    payload: dict[str, Any] = {"user_id": int(user_id), "links": [str(x).strip() for x in links if str(x or "").strip()]}
    # По официальной документации /sponsors/check принимает user_id и links.
    # chat_id оставлен как ручная совместимость, но по умолчанию выключен.
    if chat_id is not None and await get_setting("piarflow_check_include_chat_id", "0") == "1":
        payload["chat_id"] = int(chat_id)
    started = time.monotonic()
    http_status: int | None = None
    try:
        async with await http_session_context() as session:
            async with session.post(
                "https://piarflow.ru/v1/sponsors/check",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json=payload,
                timeout=15,
            ) as resp:
                http_status = resp.status
                try:
                    data = await resp.json(content_type=None)
                except Exception:
                    raw_text = await resp.text()
                    data = {"error": "invalid_json", "raw": raw_text[:1200]}
    except Exception as e:
        elapsed = int((time.monotonic() - started) * 1000)
        await log_provider_event("piarflow", event, user_id=user_id, chat_id=chat_id, status="error", duration_ms=elapsed, request={**payload, "api_key": "***"}, error=e)
        raise

    ok, reason, pending = piarflow_check_many_result_from_response(data if isinstance(data, dict) else {"response": data}, payload["links"])
    if isinstance(data, dict):
        data.setdefault("_bot_check_reason", reason)
        data.setdefault("_bot_pending_links", pending)
        data.setdefault("_bot_check_payload", {k: v for k, v in payload.items() if k != "api_key"})
    elapsed = int((time.monotonic() - started) * 1000)
    await log_provider_event(
        "piarflow",
        event,
        user_id=user_id,
        chat_id=chat_id,
        status="done" if ok else "failed",
        http_status=http_status,
        duration_ms=elapsed,
        request={**payload, "api_key": "***"},
        response=data,
    )
    return ok, data if isinstance(data, dict) else {"response": data, "_bot_check_reason": reason, "_bot_pending_links": pending}, pending


async def piarflow_check(user_id: int, link: str, chat_id: int | None = None) -> tuple[bool, dict]:
    ok, data, _pending = await piarflow_check_links(user_id, [link], chat_id, event="check_task")
    return ok, data

async def botohub_request(user_id: int, skip: bool = False) -> dict:
    token = await get_setting("botohub_token")
    if not token or await get_setting("botohub_enabled") != "1":
        data = {"error": "BotoHub disabled", "tasks": [], "completed": True}
        await log_provider_event("botohub", "get_task", user_id=user_id, status="disabled", response=data)
        return data
    payload = {"chat_id": user_id, "is_task": True, "skip": skip}
    started = time.monotonic()
    http_status: int | None = None
    try:
        async with await http_session_context() as session:
            async with session.post("https://botohub.me/get-tasks", headers={"Auth": token, "Content-Type": "application/json"}, json=payload, timeout=15) as resp:
                http_status = resp.status
                data = await resp.json(content_type=None)
    except Exception as e:
        elapsed = int((time.monotonic() - started) * 1000)
        await log_provider_event("botohub", "get_task", user_id=user_id, status="error", http_status=http_status, duration_ms=elapsed, request={**payload, "Auth": "***"}, error=e)
        raise
    elapsed = int((time.monotonic() - started) * 1000)
    status = "ok" if not (isinstance(data, dict) and data.get("error")) else "error"
    await log_provider_event("botohub", "get_task", user_id=user_id, status=status, http_status=http_status, duration_ms=elapsed, request={**payload, "Auth": "***"}, response=data)
    return data if isinstance(data, dict) else {"response": data}


async def botohub_sponsor_request(user_id: int) -> dict:
    """BotoHub advertising/OP integration: POST /get-tasks without is_task."""
    token = await get_setting("botohub_token")
    if not token or await get_setting("botohub_enabled") != "1":
        data = {"error": "BotoHub disabled", "tasks": [], "completed": True, "skip": True}
        await log_provider_event("botohub", "sponsor_request", user_id=user_id, status="disabled", response=data)
        return data
    payload = {"chat_id": user_id}
    started = time.monotonic()
    http_status: int | None = None
    try:
        async with await http_session_context() as session:
            async with session.post("https://botohub.me/get-tasks", headers={"Auth": token, "Content-Type": "application/json"}, json=payload, timeout=15) as resp:
                http_status = resp.status
                data = await resp.json(content_type=None)
    except Exception as e:
        elapsed = int((time.monotonic() - started) * 1000)
        await log_provider_event("botohub", "sponsor_request", user_id=user_id, status="error", http_status=http_status, duration_ms=elapsed, request={**payload, "Auth": "***"}, error=e)
        raise
    elapsed = int((time.monotonic() - started) * 1000)
    status = "ok" if not (isinstance(data, dict) and data.get("error")) else "error"
    await log_provider_event("botohub", "sponsor_request", user_id=user_id, status=status, http_status=http_status, duration_ms=elapsed, request={**payload, "Auth": "***"}, response=data)
    return data if isinstance(data, dict) else {"response": data}


PROVIDERS = ("subgram", "piarflow", "botohub")
DIAGNOSTIC_PROVIDERS = (*PROVIDERS, *AD_LOG_PROVIDERS)


def provider_role_key(provider: str) -> str:
    return f"provider_role_{provider}"


def provider_enabled_key(provider: str) -> str:
    return f"{provider}_enabled"


def provider_secret_key(provider: str) -> str:
    return {
        "subgram": "subgram_api_key",
        "piarflow": "piarflow_api_key",
        "botohub": "botohub_token",
    }.get(provider, "")


async def provider_role(provider: str) -> str:
    defaults = {"subgram": "op", "piarflow": "tasks", "botohub": "tasks"}
    role = await get_setting(provider_role_key(provider), defaults.get(provider, "off"))
    return role if role in {"off", "op", "tasks"} else defaults.get(provider, "off")


async def provider_has_credentials(provider: str) -> bool:
    secret_key = provider_secret_key(provider)
    return bool(secret_key and (await get_setting(secret_key, "")).strip())


async def provider_is_enabled(provider: str) -> bool:
    return await get_setting(provider_enabled_key(provider), "0") == "1" and await provider_has_credentials(provider)


async def provider_available_for_role(provider: str, role: str) -> bool:
    if provider not in PROVIDERS:
        return False
    return await provider_role(provider) == role and await provider_is_enabled(provider)


async def providers_for_role(role: str) -> list[str]:
    result = []
    for provider in PROVIDERS:
        if await provider_available_for_role(provider, role):
            result.append(provider)
    return result


async def choose_provider_for_role(role: str, setting_key: str, default: str = "auto") -> str | None:
    available = await providers_for_role(role)
    if not available:
        return None

    selected = (await get_setting(setting_key, default)).strip().lower() or "auto"
    if selected in {"mix", "random"}:
        return random.choice(available)
    if selected == "auto":
        return available[0]
    if selected in available:
        return selected

    # Если админ назначил провайдер в другой режим, не блокируем раздел, а берём доступный.
    return available[0]


URL_CANDIDATE_RE = re.compile(r'''(?:https?://|tg://|t\.me/|telegram\.me/|@[A-Za-z0-9_]{4,})[^\s"'<>)]*''')
LINK_KEYS = {
    "link", "url", "href", "button_url", "button", "invite", "invite_link",
    "channel_link", "chat_link", "sponsor_link", "task_link", "target_url",
}
CONTAINER_LINK_KEYS = {
    "tasks", "task", "sponsors", "sponsor", "channels", "channel", "links",
    "items", "results", "data", "ads", "ad", "additional", "buttons", "reply_markup",
}


def normalize_tg_link(value: str | None) -> str | None:
    raw = str(value or "").strip().strip(".,;!\n\t ")
    if not raw:
        return None
    if raw.startswith("@") and len(raw) > 1:
        return "https://t.me/" + raw[1:]
    if raw.startswith("t.me/") or raw.startswith("telegram.me/"):
        return "https://" + raw
    if raw.startswith("http://") or raw.startswith("https://") or raw.startswith("tg://"):
        return raw
    match = URL_CANDIDATE_RE.search(raw)
    if match:
        return normalize_tg_link(match.group(0))
    return None


def extract_links_deep(value: Any, *, max_depth: int = 5) -> list[str]:
    """Extract sponsor/task links from provider responses with different JSON shapes.

    BotoHub can return tasks as plain strings, dictionaries, or nested button-like
    objects. The previous parser only handled a list of strings, so OP could show
    an empty screen with only the «Я выполнил» button when links were present but
    nested in another field.
    """
    result: list[str] = []
    seen: set[str] = set()

    def add(candidate: Any) -> None:
        link = normalize_tg_link(str(candidate) if candidate is not None else "")
        if link and link not in seen:
            seen.add(link)
            result.append(link)

    def walk(obj: Any, depth: int = 0) -> None:
        if obj is None or depth > max_depth:
            return
        if isinstance(obj, str):
            add(obj)
            return
        if isinstance(obj, (list, tuple, set)):
            for item in obj:
                walk(item, depth + 1)
            return
        if isinstance(obj, dict):
            # First pass: explicit URL/link fields.
            for key, item in obj.items():
                key_l = str(key).lower()
                if key_l in LINK_KEYS or "link" in key_l or "url" in key_l:
                    if isinstance(item, (str, int, float)):
                        add(item)
                    else:
                        walk(item, depth + 1)
            # Second pass: common containers that may hold buttons/tasks/sponsors.
            for key, item in obj.items():
                key_l = str(key).lower()
                if key_l in CONTAINER_LINK_KEYS:
                    walk(item, depth + 1)
            return

    walk(value, 0)
    return result


def subgram_pending_links(response: dict | None) -> list[str]:
    sponsors = (response or {}).get("additional", {}).get("sponsors", []) or []
    links = []
    for sponsor in sponsors:
        if sponsor.get("available_now", True) and sponsor.get("status") != "subscribed" and sponsor.get("link"):
            link = normalize_tg_link(str(sponsor["link"]))
            if link:
                links.append(link)
    return links


def piarflow_links(response: dict | None) -> list[str]:
    sponsors = (response or {}).get("sponsors", []) or []
    links = []
    for sponsor in sponsors:
        link = normalize_tg_link(str(sponsor.get("link") or ""))
        if link:
            links.append(link)
    return links


def botohub_links(response: dict | None) -> list[str]:
    response = response or {}
    # Prefer task/sponsor containers, but fall back to deep extraction so new
    # BotoHub response formats do not break OP rendering.
    for key in ("tasks", "sponsors", "channels", "links", "data", "items"):
        links = extract_links_deep(response.get(key)) if isinstance(response, dict) else []
        if links:
            return links[:10]
    return extract_links_deep(response)[:10]


async def get_op_status(provider: str, user: Any, chat_id: int) -> tuple[bool, str, dict, list[str]]:
    if provider == "subgram":
        response = await subgram_request(user, chat_id, event="op_check") or {}
        status = str(response.get("status", "error")).strip().lower()
        links = subgram_pending_links(response)
        # Do not auto-pass OP on provider/API errors. Only a clear non-warning
        # successful SubGram response opens access.
        if status in {"error", "fail", "failed", "disabled"} or response.get("error"):
            return False, status or "error", response, links
        if status == "warning":
            return False, status, response, links
        return True, status or "ok", response, []

    if provider == "piarflow":
        # PiarFlow OP must be checked through /sponsors/check using the links
        # that were shown to this exact user. Re-requesting /sponsors on every
        # click only returns sponsors again and does not confirm subscriptions.
        session = await get_op_session(user.id, "piarflow")
        session_links = [str(x).strip() for x in ((session or {}).get("links") or []) if str(x or "").strip()]
        if session_links:
            ok, response, pending_links = await piarflow_check_links(user.id, session_links, chat_id, event="op_check")
            if ok:
                await clear_op_session(user.id, "piarflow")
                return True, "ok", response, []
            visible_links = pending_links or session_links
            return False, "warning", response, visible_links[:5]

        link, _reward, response = await piarflow_get_task(user.id, chat_id, event="op_get_sponsors")
        links = piarflow_links(response)
        if link and link not in links:
            links.insert(0, link)
        links = [x for x in links if x]
        if links:
            await save_op_session(user.id, "piarflow", links, response, status="pending")
            return False, "warning", response, links[:5]
        await clear_op_session(user.id, "piarflow")
        return True, "ok", response, []

    if provider == "botohub":
        response = await botohub_sponsor_request(user.id)
        links = botohub_links(response)
        if response.get("error"):
            return False, "error", response, links[:5]
        if not response.get("completed") and links:
            return False, "warning", response, links[:5]
        if not response.get("completed") and not links:
            return False, "warning", response, []
        return True, "ok", response, []

    return True, "disabled", {"provider": provider, "message": "unknown provider"}, []


async def subgram_get_task(user: Any, chat_id: int) -> tuple[str | None, float, dict]:
    response = await subgram_request(user, chat_id, event="get_task") or {}
    links = subgram_pending_links(response)
    if not links:
        return None, 0, response
    reward = await fixed_task_reward("subgram")
    return links[0], reward, response


async def subgram_check_task(user: Any, chat_id: int, link: str) -> tuple[bool, dict]:
    response = await subgram_request(user, chat_id, event="check_task") or {}
    status = str(response.get("status", "")).strip().lower()
    if status in {"error", "fail", "failed", "disabled"} or response.get("error"):
        return False, response
    if status != "warning":
        return True, response
    pending = set(subgram_pending_links(response))
    return bool(link and link not in pending), response


async def last_provider_log(provider: str) -> str:
    async with await db() as conn:
        cur = await conn.execute(
            """
            SELECT status, event, created_at, duration_ms, error FROM provider_event_logs
            WHERE provider=? ORDER BY id DESC LIMIT 1
            """,
            (provider,),
        )
        row = await cur.fetchone()
        if not row:
            cur = await conn.execute(
                """
                SELECT status, created_at, NULL as event, NULL as duration_ms, NULL as error FROM (
                    SELECT service, status, created_at FROM op_logs
                    UNION ALL
                    SELECT service, status, created_at FROM task_logs
                ) WHERE service=? ORDER BY created_at DESC LIMIT 1
                """,
                (provider,),
            )
            row = await cur.fetchone()
    if not row:
        return "логов нет"
    duration = f" · {int(row['duration_ms'])} ms" if row['duration_ms'] is not None else ""
    error = f" · {str(row['error'])[:80]}" if row['error'] else ""
    event = f"{row['event']} · " if row['event'] else ""
    return f"{event}{row['status']}{duration} · {row['created_at']}{error}"


async def provider_logs_text(provider: str = "all", limit: int = 12) -> str:
    async with await db() as conn:
        if provider == "all":
            cur = await conn.execute("SELECT * FROM provider_event_logs ORDER BY id DESC LIMIT ?", (limit,))
        else:
            cur = await conn.execute("SELECT * FROM provider_event_logs WHERE provider=? ORDER BY id DESC LIMIT ?", (provider, limit))
        rows = await cur.fetchall()
    title = "Все провайдеры" if provider == "all" else provider.upper()
    lines = [f"{ce('file', '📁')} <b>Логи провайдеров: {html.escape(title)}</b>", ""]
    if not rows:
        lines.append("<i>Логов пока нет. Нажмите проверку API или выполните задание.</i>")
        return "\n".join(lines)
    for row in rows:
        status_icon = ce("check", "✅") if str(row["status"]) in {"ok", "done", "success"} else ce("info", "ℹ") if str(row["status"]) in {"empty", "warning", "disabled"} else ce("cross", "❌")
        duration = f" · {int(row['duration_ms'])} ms" if row["duration_ms"] is not None else ""
        http_status = f" · HTTP {int(row['http_status'])}" if row["http_status"] is not None else ""
        error = f"\n  Ошибка: <code>{html.escape(str(row['error'])[:220])}</code>" if row["error"] else ""
        response_summary = ""
        if row["response_json"]:
            try:
                response_summary = safe_response_summary(json.loads(row["response_json"]), 360)
            except Exception:
                response_summary = str(row["response_json"])[:360]
            response_summary = f"\n  Ответ: <code>{html.escape(response_summary)}</code>"
        lines.append(
            f"{status_icon} <b>{html.escape(str(row['provider']).upper())}</b> · <code>{html.escape(str(row['event']))}</code> · <b>{html.escape(str(row['status']))}</b>{http_status}{duration}\n"
            f"  user: <code>{html.escape(str(row['user_id'] or '-'))}</code> · {html.escape(str(row['created_at']))}"
            f"{error}{response_summary}"
        )
    return "\n\n".join(lines)[:3900]


def provider_logs_kb(provider: str = "all") -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Все", callback_data="diag:logs:all", icon="file")],
        [ibtn("SubGram", callback_data="diag:logs:subgram", icon="apps"), ibtn("PiarFlow", callback_data="diag:logs:piarflow", icon="apps")],
        [ibtn("BotoHub", callback_data="diag:logs:botohub", icon="apps"), ibtn("BotoHub Views", callback_data="diag:logs:botohub_views", icon="eye")],
        [ibtn("HiViews", callback_data="diag:logs:hiviews", icon="apps"), ibtn("Start Ads", callback_data="diag:logs:start_ads", icon="stats")],
        [ibtn("Диагностика", callback_data="admin:diagnostics", icon="back"), ibtn("Админка", callback_data="admin:menu", icon="home")],
    ])


async def provider_config_snapshot(provider: str) -> dict[str, Any]:
    role = await provider_role(provider)
    enabled = await get_setting(provider_enabled_key(provider), "0") == "1"
    has_token = await provider_has_credentials(provider)
    available_op = await provider_available_for_role(provider, "op")
    available_tasks = await provider_available_for_role(provider, "tasks")
    last_log = await last_provider_log(provider)
    return {
        "provider": provider,
        "role": role,
        "enabled": enabled,
        "has_token": has_token,
        "available_op": available_op,
        "available_tasks": available_tasks,
        "last_log": last_log,
    }


def yes_no(value: bool) -> str:
    return f"{ce('check', '✅')} да" if value else f"{ce('cross', '❌')} нет"


async def diagnostics_text(title: str = "Диагностика провайдеров", extra: str | None = None) -> str:
    current_op = await choose_provider_for_role("op", "op_provider", "auto")
    current_tasks = await choose_provider_for_role("tasks", "tasks_provider", "auto")
    start_provider = await start_ad_selected_provider()
    last_start_log = await last_provider_log("start_ads")
    lines = [
        f"{ce('info', 'ℹ')} <b>{html.escape(title)}</b>",
        "",
        f"Провайдер ОП сейчас: <b>{html.escape(current_op or 'нет доступного')}</b>",
        f"Провайдер заданий сейчас: <b>{html.escape(current_tasks or 'нет доступного')}</b>",
        f"Start-реклама сейчас: <b>{html.escape(start_provider)}</b>",
        f"Последний start_ads лог: <code>{html.escape(str(last_start_log))}</code>",
        "",
    ]
    views_enabled = await get_setting("botohub_views_enabled", "1") == "1"
    views_token = bool((await get_setting("botohub_views_token", "")).strip() or (await get_setting("botohub_token", "")).strip())
    hiviews_enabled = await get_setting("hiviews_enabled", "1") == "1" or await get_setting("hiwiews_enabled", "1") == "1"
    hiviews_token = bool((await get_setting("hiviews_api_key", "")).strip())
    lines.extend([
        "<b>START ADS / VIEWS</b>",
        f"Start-реклама включена: {yes_no(await get_setting('start_ad_enabled', '1') == '1')}",
        f"Выбранный провайдер: <code>{html.escape(start_provider)}</code>",
        f"BotoHub Views: {yes_no(views_enabled)} · токен: {yes_no(views_token)} · лог: <code>{html.escape(str(await last_provider_log('botohub_views')))}</code>",
        f"HiViews: {yes_no(hiviews_enabled)} · ключ: {yes_no(hiviews_token)} · лог: <code>{html.escape(str(await last_provider_log('hiviews')))}</code>",
        f"BotoHub вне /start: {yes_no(await get_setting('botohub_views_regular_enabled', '1') == '1')} · пауза <code>{html.escape(await get_setting('botohub_views_regular_cooldown_minutes', '10'))} мин.</code> · шанс <code>{html.escape(await get_setting('botohub_views_regular_chance_percent', '35'))}%</code>",
        "",
    ])

    for provider in PROVIDERS:
        snap = await provider_config_snapshot(provider)
        lines.extend([
            f"<b>{provider.upper()}</b>",
            f"Роль: <code>{html.escape(snap['role'])}</code>",
            f"Включён: {yes_no(bool(snap['enabled']))}",
            f"Токен задан: {yes_no(bool(snap['has_token']))}",
            f"Доступен для ОП: {yes_no(bool(snap['available_op']))}",
            f"Доступен для заданий: {yes_no(bool(snap['available_tasks']))}",
            f"Последний лог: <code>{html.escape(str(snap['last_log']))}</code>",
            "",
        ])
    if extra:
        lines.extend(["<b>Результат проверки:</b>", extra])
    return "\n".join(lines)[:3900]

def diagnostics_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Проверить все", callback_data="diag:check:all", icon="loading")],
        [ibtn("SubGram", callback_data="diag:check:subgram", icon="apps"), ibtn("PiarFlow", callback_data="diag:check:piarflow", icon="apps")],
        [ibtn("BotoHub", callback_data="diag:check:botohub", icon="apps"), ibtn("BotoHub Views", callback_data="diag:check:botohub_views", icon="eye")],
        [ibtn("HiViews", callback_data="diag:check:hiviews", icon="apps"), ibtn("Start-провайдер", callback_data="cfg:key:start_ad_provider", icon="settings")],
        [ibtn("Логи провайдеров", callback_data="diag:logs:all", icon="file")],
        [ibtn("API настройки", callback_data="admin:api", icon="apps"), ibtn("Админка", callback_data="admin:menu", icon="home")],
    ])


async def check_provider_api(provider: str, user: Any, chat_id: int) -> tuple[bool, str]:
    provider = str(provider or "").strip().lower()

    if provider == "botohub_views":
        enabled = await get_setting("botohub_views_enabled", "1") == "1"
        has_token = await botohub_views_has_token()
        if not enabled:
            return False, "botohub_views: выключен в настройках"
        if not has_token:
            return False, "botohub_views: token не задан"
        started = time.monotonic()
        ok, data = await botohub_views_send_post(int(chat_id), is_hi=True, placement="diagnostics")
        elapsed_ms = int((time.monotonic() - started) * 1000)
        code = data.get("SendPostResult") if isinstance(data, dict) else None
        name = data.get("ResultName") if isinstance(data, dict) else None
        return ok, f"botohub_views: {'OK' if ok else 'FAIL'} · {elapsed_ms} ms · result={code} {html.escape(str(name or ''))}"

    if provider == "hiviews":
        enabled = await get_setting("hiviews_enabled", "1") == "1" or await get_setting("hiwiews_enabled", "1") == "1"
        has_token = await hiviews_has_token()
        last = await last_provider_log("hiviews")
        if not enabled:
            return False, "hiviews: выключен в настройках"
        if not has_token:
            return False, "hiviews: API key не задан"
        return True, f"hiviews: OK · ключ задан; боевой POST выполняется только первой строкой на /start; последний лог: {html.escape(str(last))}"

    if provider == "start_ads":
        mode = await start_ad_selected_provider()
        candidates = await start_ad_candidate_order()
        return bool(candidates), f"start_ads: mode={html.escape(mode)}; candidates={html.escape(','.join(candidates) or 'none')}"

    if provider not in PROVIDERS:
        return False, f"{provider}: неизвестный провайдер"

    enabled = await get_setting(provider_enabled_key(provider), "0") == "1"
    has_token = await provider_has_credentials(provider)
    role = await provider_role(provider)
    if not enabled:
        return False, f"{provider}: выключен в настройках"
    if not has_token:
        return False, f"{provider}: токен/ключ не задан"
    if role == "off":
        return False, f"{provider}: роль off"

    started = time.monotonic()
    try:
        if provider == "subgram":
            response = await subgram_request(user, chat_id, event="api_check") or {}
            status = str(response.get("status", "unknown"))
            links = len(subgram_pending_links(response))
            ok = status in {"ok", "warning"}
            details = f"status={status}; pending_links={links}"
        elif provider == "piarflow":
            link, reward, response = await piarflow_get_task(user.id, chat_id)
            if isinstance(response, dict) and response.get("error"):
                ok = False
                details = str(response.get("error"))
            else:
                ok = True
                details = f"task={'есть' if link else 'нет'}; sponsors={len(piarflow_links(response))}; reward={fmt_amount(float(reward or 0))}; max={await get_setting('piarflow_max_sponsors', '5')}"
        else:
            response = await botohub_request(user.id, skip=False)
            if isinstance(response, dict) and response.get("error"):
                ok = False
                details = str(response.get("error"))
            else:
                ok = True
                details = f"completed={bool(response.get('completed'))}; tasks={len(botohub_links(response))}"
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return ok, f"{provider}: {'OK' if ok else 'FAIL'} · {elapsed_ms} ms · {html.escape(details)}"
    except Exception as e:
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return False, f"{provider}: FAIL · {elapsed_ms} ms · {html.escape(str(e))}"


async def get_current_task(user_id: int) -> Optional[aiosqlite.Row]:
    async with await db() as conn:
        cur = await conn.execute("SELECT * FROM task_sessions WHERE user_id=?", (user_id,))
        return await cur.fetchone()


async def save_task(user_id: int, service: str, link: str, reward: float, status: str = "pending") -> int:
    old = await get_current_task(user_id)
    num = int(old["task_num"] if old else 0) + 1 if old and old["status"] == "done" else int(old["task_num"] if old else 1)
    async with await db() as conn:
        await conn.execute(
            "INSERT INTO task_sessions(user_id,service,link,reward,task_num,status,updated_at) VALUES(?,?,?,?,?,?,?) "
            "ON CONFLICT(user_id) DO UPDATE SET service=excluded.service, link=excluded.link, reward=excluded.reward, task_num=excluded.task_num, status=excluded.status, updated_at=excluded.updated_at",
            (user_id, service, link, reward, num, status, now_iso()),
        )
        await conn.commit()
    return num


def task_kb(link: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Выполнить", url=link, icon="link")],
        [ibtn("Пропустить задачу", callback_data="task:skip", icon="down")],
        [ibtn("Я выполнил", callback_data="task:check", icon="check")],
    ])


async def issue_task(
    message: Message,
    skip: bool = False,
    *,
    user: Any | None = None,
    chat_id: int | None = None,
    show_empty: bool = True,
    cleanup_before: bool = True,
    provider_hint: str | None = None,
    provider_response: dict | None = None,
) -> bool:
    """Issue the next available task and return True if a task was sent.

    callback.message.from_user is usually the bot, not the real user, so callbacks
    pass user/chat_id explicitly. This keeps automatic next-task delivery stable.
    """
    task_user = user or getattr(message, "from_user", None)
    if not task_user:
        if show_empty:
            await animated_answer(message, f"{ce('info', 'ℹ')} <b>Не удалось определить пользователя</b>\n\n<i>Открой раздел заданий ещё раз.</i>", track_scope="task_status")
        return False

    user_id = int(task_user.id)
    actual_chat_id = chat_id or getattr(getattr(message, "chat", None), "id", user_id)

    if cleanup_before:
        await cleanup_task_flow(message, user_id)

    provider = None
    if provider_hint in PROVIDERS and await provider_available_for_role(provider_hint, "tasks"):
        provider = provider_hint
    if provider is None:
        provider = await choose_provider_for_role("tasks", "tasks_provider", "auto")

    if not provider:
        if show_empty:
            await animated_answer(message, f"{ce('info', 'ℹ')} <b>Задания временно недоступны</b>\n\n<i>Нет активных провайдеров для заданий. Проверьте роли провайдеров в админке.</i>", track_scope="task_status", track_user_id=user_id)
        return False

    empty_text = f"{ce('party', '🎉')} <b>Заданий пока нет</b>\n\n<i>Загляни чуть позже — новые задания появляются постепенно.</i>"

    if provider == "botohub":
        data = provider_response if provider_response is not None else await botohub_request(user_id, skip=skip)
        old = await get_current_task(user_id)
        if data.get("prev_success") and old and old["status"] == "pending":
            old_reward = float(old["reward"])
            async with await db() as conn:
                # Mark task done and pay inside one transaction so repeated checks cannot pay twice.
                cur_update = await conn.execute(
                    "UPDATE task_sessions SET status='done', updated_at=? WHERE user_id=? AND status='pending'",
                    (now_iso(), user_id),
                )
                if cur_update.rowcount == 1:
                    await conn.execute("UPDATE users SET balance=balance+? WHERE id=?", (old_reward, user_id))
                    await conn.execute("INSERT INTO task_logs(user_id,service,link,reward,status,response_json,created_at) VALUES(?,?,?,?,?,?,?)", (user_id, "botohub", old["link"], old_reward, "done", json.dumps(data, ensure_ascii=False), now_iso()))
                    await conn.commit()
                    invalidate_user_cache(user_id)
                    await animated_answer(message, f"{ce('check', '✅')} <b>Задание принято</b>\n\nНачислено: <b>{fmt_amount(old_reward)}⭐</b>", track_scope="task_status", track_user_id=user_id)
                else:
                    await conn.commit()
        links = data.get("tasks", []) or []
        if data.get("completed") or data.get("skip") or not links:
            if show_empty:
                await animated_answer(message, empty_text, track_scope="task_status", track_user_id=user_id)
            return False
        reward = await fixed_task_reward("botohub")
        link = links[0]
        num = await save_task(user_id, "botohub", link, reward)
    elif provider == "subgram":
        try:
            link, reward, data = await subgram_get_task(task_user, actual_chat_id)
        except Exception as e:
            if show_empty:
                await animated_answer(message, f"{ce('info', 'ℹ')} Не удалось получить задание SubGram: {html.escape(str(e))}", track_scope="task_status", track_user_id=user_id)
            return False
        if not link:
            if show_empty:
                await animated_answer(message, empty_text, track_scope="task_status", track_user_id=user_id)
            return False
        num = await save_task(user_id, "subgram", link, reward)
    else:
        try:
            link, reward, data = await piarflow_get_task(user_id, actual_chat_id)
        except Exception as e:
            if show_empty:
                await animated_answer(message, f"{ce('info', 'ℹ')} Не удалось получить задание PiarFlow: {html.escape(str(e))}", track_scope="task_status", track_user_id=user_id)
            return False
        if not link:
            if show_empty:
                await animated_answer(message, empty_text, track_scope="task_status", track_user_id=user_id)
            return False
        num = await save_task(user_id, "piarflow", link, reward)

    text = (await get_setting("task_text")).format(num=num, link=link, reward=fmt_amount(reward))
    await animated_answer(message, text, reply_markup=task_kb(link), track_scope="task", track_user_id=user_id)
    return True


@router.message(F.text.in_({"Задания", "💎 Задания"}))
async def tasks_menu(message: Message) -> None:
    await cleanup_task_flow(message, message.from_user.id if message.from_user else None)
    await animated_answer(message, await get_setting("tasks_top_text"), track_scope="task_header")
    await issue_task(message, skip=False, cleanup_before=False)
    schedule_maybe_regular_ad(message, message.from_user.id if message.from_user else None, reason="task")


@router.callback_query(F.data == "task:skip")
async def task_skip(callback: CallbackQuery) -> None:
    await callback.answer("Задача пропущена")
    async with await db() as conn:
        await conn.execute("UPDATE task_sessions SET status='skipped', updated_at=? WHERE user_id=?", (now_iso(), callback.from_user.id))
        await conn.commit()
    await cleanup_task_flow(callback.message, callback.from_user.id)
    await animated_answer(callback.message, f"{ce('down', '📰')} <b>Задание пропущено</b>\n\n<i>Подбираю следующее доступное задание.</i>", track_scope="task_status", track_user_id=callback.from_user.id)
    await issue_task(callback.message, skip=True, user=callback.from_user, chat_id=callback.message.chat.id, cleanup_before=False)
    schedule_maybe_regular_ad(callback.message, callback.from_user.id, reason="task")


@router.callback_query(F.data == "task:check")
async def task_check(callback: CallbackQuery) -> None:
    session = await get_current_task(callback.from_user.id)
    if not session or session["status"] != "pending":
        await callback.answer("Нет активного задания", show_alert=True)
        return
    service = session["service"]
    link = session["link"]
    reward = float(session["reward"])
    ok = False
    data: dict = {}
    try:
        if service == "piarflow":
            ok, data = await piarflow_check(callback.from_user.id, link, callback.message.chat.id)
        elif service == "botohub":
            data = await botohub_request(callback.from_user.id, skip=False)
            ok = bool(data.get("prev_success"))
        elif service == "subgram":
            ok, data = await subgram_check_task(callback.from_user, callback.message.chat.id, link)
        else:
            data = {"error": f"unknown task provider: {service}"}
            ok = False
    except Exception as e:
        await callback.answer("Ошибка проверки", show_alert=True)
        await animated_answer(callback.message, f"{ce('info', 'ℹ')} Ошибка проверки задания: {html.escape(str(e))}", track_scope="task_status", track_user_id=callback.from_user.id)
        return
    if not ok:
        async with await db() as conn:
            await conn.execute("INSERT INTO task_logs(user_id,service,link,reward,status,response_json,created_at) VALUES(?,?,?,?,?,?,?)", (callback.from_user.id, service, link, reward, "failed", json.dumps(data, ensure_ascii=False), now_iso()))
            await conn.commit()
        await callback.answer("Не выполнено", show_alert=True)
        await cleanup_bot_messages(callback.message, callback.from_user.id, scopes=["task_status"])
        await animated_answer(callback.message, await get_setting("task_not_done_text"), track_scope="task_status", track_user_id=callback.from_user.id)
        return
    async with await db() as conn:
        # Atomic completion: a double-click on "Я выполнил" must not duplicate rewards.
        cur_update = await conn.execute(
            "UPDATE task_sessions SET status='done', updated_at=? WHERE user_id=? AND status='pending'",
            (now_iso(), callback.from_user.id),
        )
        if cur_update.rowcount != 1:
            await conn.commit()
            await callback.answer("Задание уже обработано", show_alert=True)
            return
        await conn.execute("UPDATE users SET balance=balance+? WHERE id=?", (reward, callback.from_user.id))
        await conn.execute("INSERT INTO task_logs(user_id,service,link,reward,status,response_json,created_at) VALUES(?,?,?,?,?,?,?)", (callback.from_user.id, service, link, reward, "done", json.dumps(data, ensure_ascii=False), now_iso()))
        await conn.commit()
    invalidate_user_cache(callback.from_user.id)
    await callback.answer("Готово")
    await cleanup_task_flow(callback.message, callback.from_user.id)
    await animated_answer(callback.message, f"{ce('check', '✅')} <b>Задание принято</b>\n\nНачислено: <b>{fmt_amount(reward)}⭐</b>", track_scope="task_status", track_user_id=callback.from_user.id)
    if await get_setting("auto_next_task_after_completion", "1") == "1":
        await issue_task(
            callback.message,
            skip=False,
            user=callback.from_user,
            chat_id=callback.message.chat.id,
            provider_hint=service,
            provider_response=data if service == "botohub" else None,
            show_empty=True,
            cleanup_before=False,
        )
    schedule_maybe_regular_ad(callback.message, callback.from_user.id, reason="task")


@router.message(F.text.in_({"Бонус и игры", "💰 Бонус и игры"}))
async def bonus_games(message: Message) -> None:
    await cleanup_general_flow(message, message.from_user.id if message.from_user else None)
    await show_games_menu(message, message.from_user.id)


@router.callback_query(F.data == "daily_bonus")
async def daily_bonus(callback: CallbackQuery) -> None:
    user_id = callback.from_user.id
    async with await db() as conn:
        cur = await conn.execute("SELECT created_at FROM bonus_logs WHERE user_id=? ORDER BY id DESC LIMIT 1", (user_id,))
        last = await cur.fetchone()
    last_dt = parse_dt(last["created_at"] if last else None)
    if last_dt and datetime.now(timezone.utc) - last_dt < timedelta(hours=24):
        left = timedelta(hours=24) - (datetime.now(timezone.utc) - last_dt)
        hours = int(left.total_seconds() // 3600)
        minutes = int((left.total_seconds() % 3600) // 60)
        await callback.answer("Бонус уже получен", show_alert=True)
        await animated_answer(callback.message, (await get_setting("bonus_wait_text")).format(hours=hours, minutes=minutes))
        return
    mn = max(0.0, await get_float_setting("daily_bonus_min", 0.01))
    mx = max(0.0, await get_float_setting("daily_bonus_max", 0.10))
    if mx < mn:
        mn, mx = mx, mn
    amount = round(random.uniform(mn, mx), 2)
    async with await db() as conn:
        # Lock the DB while checking/inserting so double-clicks cannot claim two bonuses.
        await conn.execute("BEGIN IMMEDIATE")
        cur = await conn.execute("SELECT created_at FROM bonus_logs WHERE user_id=? ORDER BY id DESC LIMIT 1", (user_id,))
        locked_last = await cur.fetchone()
        locked_last_dt = parse_dt(locked_last["created_at"] if locked_last else None)
        if locked_last_dt and datetime.now(timezone.utc) - locked_last_dt < timedelta(hours=24):
            left = timedelta(hours=24) - (datetime.now(timezone.utc) - locked_last_dt)
            await conn.commit()
            hours = int(left.total_seconds() // 3600)
            minutes = int((left.total_seconds() % 3600) // 60)
            await callback.answer("Бонус уже получен", show_alert=True)
            await animated_answer(callback.message, (await get_setting("bonus_wait_text")).format(hours=hours, minutes=minutes))
            return
        await conn.execute("INSERT INTO bonus_logs(user_id,amount,created_at) VALUES(?,?,?)", (user_id, amount, now_iso()))
        await conn.execute("UPDATE users SET balance=balance+? WHERE id=?", (amount, user_id))
        await conn.commit()
    invalidate_user_cache(user_id)
    await animated_answer(callback.message, (await get_setting("bonus_received_text")).format(amount=fmt_amount(amount)))
    schedule_maybe_regular_ad(callback.message, user_id, reason="bonus")
    await callback.answer("Бонус начислен")



GAME_DICE_EMOJI = {
    "slots": "🎰",
    "dice": "🎲",
    "basket": "🏀",
    "bowling": "🎳",
}

GAME_TITLES = {
    "slots": "Слоты",
    "dice": "Кости",
    "basket": "Баскетбол",
    "bowling": "Боулинг",
}

GAME_BUTTON_ICONS = {
    "slots": "gift",
    "dice": "apps",
    "basket": "party",
    "bowling": "box",
}


def normalize_game_name(game: str) -> str:
    aliases = {"slot": "slots", "casino": "slots", "кубик": "dice", "dice": "dice", "basketball": "basket"}
    game = (game or "").strip().lower()
    return aliases.get(game, game)


async def get_user_game_bet(user_id: int | None) -> float:
    default_bet = await get_float_setting("game_default_bet", 1.0)
    if user_id is None:
        return default_bet
    try:
        async with await db() as conn:
            cur = await conn.execute("SELECT bet FROM game_bets WHERE user_id=?", (int(user_id),))
            row = await cur.fetchone()
        if row and float(row["bet"]) > 0:
            return float(row["bet"])
    except Exception:
        pass
    return default_bet


async def set_user_game_bet(user_id: int, bet: float) -> None:
    async with await db() as conn:
        await conn.execute(
            "INSERT INTO game_bets(user_id,bet,updated_at) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET bet=excluded.bet, updated_at=excluded.updated_at",
            (int(user_id), float(bet), now_iso()),
        )
        await conn.commit()


async def game_bet_presets() -> list[float]:
    raw = await get_setting("game_bet_presets", "0.1,0.25,0.5,1,2,5")
    presets: list[float] = []
    for part in raw.replace(";", ",").split(","):
        part = part.strip().replace(",", ".")
        if not part:
            continue
        try:
            value = float(part)
            if value > 0 and value not in presets:
                presets.append(value)
        except Exception:
            continue
    return presets or [0.1, 0.25, 0.5, 1.0, 2.0, 5.0]


def slot_bits(value: int) -> tuple[int, int, int]:
    # Telegram encodes 🎰 as three 2-bit values inside the 1..64 dice value.
    raw = max(0, min(63, int(value) - 1))
    return raw & 3, (raw >> 2) & 3, (raw >> 4) & 3


def game_outcome(game: str, dice_value: int, bet: float) -> tuple[float, str, str]:
    """Return win amount, short result and explanation for the actual Telegram dice value."""
    game = normalize_game_name(game)
    value = int(dice_value or 0)

    if game == "basket":
        if value >= 5:
            mult, title, detail = 2.3, "Чистое попадание", "Мяч залетел идеально — ставка сыграла красиво."
        elif value == 4:
            mult, title, detail = 1.5, "Попадание", "Есть попадание, забираем хороший выигрыш."
        else:
            mult, title, detail = 0.0, "Мимо кольца", "На этот раз бросок не зашёл. Попробуем ещё?"
        return round(bet * mult, 2), title, detail

    if game == "bowling":
        if value >= 6:
            mult, title, detail = 3.0, "Страйк", "Все кегли легли — отличный бросок."
        elif value == 5:
            mult, title, detail = 1.8, "Почти страйк", "Кегли разлетелись, выигрыш уже на балансе."
        elif value == 4:
            mult, title, detail = 1.2, "Хороший бросок", "Не максимум, но ставка вернулась с плюсом."
        else:
            mult, title, detail = 0.0, "Не повезло", "Дорожка сегодня капризная. Следующий бросок может быть лучше."
        return round(bet * mult, 2), title, detail

    if game == "dice":
        if value == 6:
            mult, title, detail = 2.0, "Выпала шестёрка", "Максимальный бросок — забираем x2."
        elif value == 5:
            mult, title, detail = 1.5, "Выпала пятёрка", "Сильный бросок, ставка сыграла."
        elif value == 4:
            mult, title, detail = 1.1, "Выпала четвёрка", "Небольшой плюс — тоже приятно."
        else:
            mult, title, detail = 0.0, f"Выпало {value}", "Сегодня кубик не на нашей стороне."
        return round(bet * mult, 2), title, detail

    # slots
    left, center, right = slot_bits(value)
    if (left, center, right) == (3, 3, 3):
        mult, title, detail = 7.0, "Джекпот 777", "Слоты выдали главную комбинацию."
    elif left == center == right:
        mult, title, detail = 5.0, "Три одинаковых", "Красивая линия — крупный выигрыш."
    elif left == center or center == right:
        mult, title, detail = 2.0, "Пара в линии", "Две одинаковые подряд — ставка сыграла."
    else:
        mult, title, detail = 0.0, "Без совпадений", "Барабаны прокрутились мимо выигрышной линии."
    return round(bet * mult, 2), title, detail


async def game_result_kb(user_id: int, game: str) -> InlineKeyboardMarkup:
    bet = await get_user_game_bet(user_id)
    game = normalize_game_name(game)
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn(f"{fmt_amount(bet)} | Изменить ставку", callback_data="game:bet", icon="star")],
        [
            ibtn("Играть ещё", callback_data=f"game:play:{game}", icon=GAME_BUTTON_ICONS.get(game, "apps")),
            ibtn("Назад", callback_data="game:menu", icon="back"),
        ],
    ])


async def game_bet_menu_text(user_id: int) -> str:
    row = await get_user(user_id)
    balance = float(row["balance"] if row else 0)
    current = await get_user_game_bet(user_id)
    return (
        f"{ce('money', '🪙')} <b>Выбор ставки</b>\n\n"
        f"<b>Текущая ставка:</b> {fmt_amount(current)}⭐\n"
        f"<b>Баланс:</b> {fmt_amount(balance)}⭐\n\n"
        f"<blockquote>Выбери удобную ставку. Она сохранится для всех игр.</blockquote>"
    )


async def game_bet_menu_kb(user_id: int) -> InlineKeyboardMarkup:
    current = await get_user_game_bet(user_id)
    presets = await game_bet_presets()
    rows: list[list[InlineKeyboardButton]] = []
    line: list[InlineKeyboardButton] = []
    for value in presets:
        mark = "✓ " if abs(value - current) < 1e-9 else ""
        line.append(ibtn(f"{mark}{fmt_amount(value)}", callback_data=f"game:bet:{fmt_amount(value)}", icon="star"))
        if len(line) == 3:
            rows.append(line)
            line = []
    if line:
        rows.append(line)
    rows.append([ibtn("Назад к играм", callback_data="game:menu", icon="back")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def show_games_menu(message: Message, user_id: int) -> None:
    row = await get_user(user_id)
    balance = float(row["balance"] if row else 0)
    bet = await get_user_game_bet(user_id)
    text = (
        f"{ce('gift', '🎁')} <b>Бонусы и игры</b>\n\n"
        f"<b>Баланс:</b> {fmt_amount(balance)}⭐\n"
        f"<b>Ставка:</b> {fmt_amount(bet)}⭐\n\n"
        f"<i>Выбери игру и дождись окончания анимации — результат считается только по тому, что выпало в Telegram.</i>\n\n"
        f"<blockquote>Кости, слоты, баскетбол и боулинг используют настоящие Telegram-анимации.</blockquote>"
    )
    await animated_answer(message, text, reply_markup=await bonus_menu(user_id), track_scope="game", track_user_id=user_id)
    schedule_maybe_regular_ad(message, user_id, reason="menu")


async def play_game(callback: CallbackQuery, game: str) -> None:
    game = normalize_game_name(game)
    if game not in GAME_DICE_EMOJI:
        await callback.answer("Игра не найдена", show_alert=True)
        return

    user_id = callback.from_user.id
    bet = await get_user_game_bet(user_id)
    # Atomic bet reservation before the animation. This prevents double-clicks
    # and parallel callbacks from spending the same balance twice.
    async with await db() as conn:
        cur_update = await conn.execute(
            "UPDATE users SET balance=balance-? WHERE id=? AND balance>=?",
            (bet, user_id, bet),
        )
        if cur_update.rowcount != 1:
            cur_balance = await conn.execute("SELECT balance FROM users WHERE id=?", (user_id,))
            balance_row = await cur_balance.fetchone()
            balance = float(balance_row["balance"] if balance_row else 0)
            await conn.commit()
            invalidate_user_cache(user_id)
            await callback.answer("Недостаточно звёзд для ставки", show_alert=True)
            await animated_answer(
                callback.message,
                f"{ce('cross', '❌')} <b>Недостаточно звёзд</b>\n\nНужно: <b>{fmt_amount(bet)}⭐</b>\nНа балансе: <b>{fmt_amount(balance)}⭐</b>",
                reply_markup=await game_result_kb(user_id, game),
                track_scope="game_result",
                track_user_id=user_id,
            )
            return
        cur_balance = await conn.execute("SELECT balance FROM users WHERE id=?", (user_id,))
        balance_row = await cur_balance.fetchone()
        balance_after_bet = float(balance_row["balance"] if balance_row else 0)
        await conn.commit()
    invalidate_user_cache(user_id)

    await callback.answer("Запускаем анимацию…")

    if await get_setting("game_message_cleanup_enabled", "1") == "1":
        await cleanup_bot_messages(callback.message, user_id, scopes=["game_dice", "game_result"], limit=20)

    dice_message: Message | None = None
    dice_value = 0
    emoji = GAME_DICE_EMOJI[game]
    if await get_setting("game_animation_enabled", "1") == "1":
        try:
            dice_message = await callback.message.bot.send_dice(chat_id=callback.message.chat.id, emoji=emoji)
            await remember_bot_message(dice_message, scope="game_dice", user_id=user_id)
            dice_value = int(getattr(getattr(dice_message, "dice", None), "value", 0) or 0)
        except Exception as e:
            log.warning("send_dice failed, fallback random result: %s", e)

    # Fallback if Telegram animation failed for any reason.
    if not dice_value:
        if game in {"dice", "bowling"}:
            dice_value = random.randint(1, 6)
        elif game == "basket":
            dice_value = random.randint(1, 5)
        else:
            dice_value = random.randint(1, 64)

    delay = max(0, min(await get_int_setting("game_animation_result_delay", 3), 6))
    if await get_setting("game_animation_enabled", "1") == "1" and delay:
        await asyncio.sleep(delay)

    win, result_title, detail = game_outcome(game, dice_value, bet)
    async with await db() as conn:
        await conn.execute("UPDATE users SET balance=balance+? WHERE id=?", (win, user_id))
        await conn.execute(
            "INSERT INTO game_logs(user_id,game,bet,win,result,created_at) VALUES(?,?,?,?,?,?)",
            (user_id, game, bet, win, f"{result_title}; value={dice_value}", now_iso()),
        )
        cur_balance = await conn.execute("SELECT balance FROM users WHERE id=?", (user_id,))
        balance_row = await cur_balance.fetchone()
        new_balance = float(balance_row["balance"] if balance_row else balance_after_bet + win)
        await conn.commit()
    invalidate_user_cache(user_id)
    if win > 0:
        header = f"{ce('party', '🎉')} <b>Поздравляем! Вы выиграли +{fmt_amount(win)}⭐</b>"
    else:
        header = f"{ce('info', 'ℹ')} <b>{html.escape(result_title)}</b>"

    text = (
        f"{header}\n\n"
        f"<i>{html.escape(detail)}</i>\n\n"
        f"<blockquote>"
        f"Игра: <b>{html.escape(GAME_TITLES.get(game, game))}</b>\n"
        f"Выпало значение: <b>{dice_value}</b>\n"
        f"Ставка: <b>{fmt_amount(bet)}⭐</b>\n"
        f"Выигрыш: <b>{fmt_amount(win)}⭐</b>"
        f"</blockquote>\n\n"
        f"<b>Ваш баланс:</b> {fmt_amount(new_balance)}⭐"
    )
    await animated_answer(callback.message, text, reply_markup=await game_result_kb(user_id, game), track_scope="game_result", track_user_id=user_id)
    schedule_maybe_regular_ad(callback.message, user_id, reason="game")


@router.callback_query(F.data.startswith("game:"))
async def game_callback(callback: CallbackQuery) -> None:
    data = callback.data or ""
    user_id = callback.from_user.id

    if data == "game:menu":
        await callback.answer()
        if await get_setting("game_message_cleanup_enabled", "1") == "1":
            await cleanup_bot_messages(callback.message, user_id, scopes=["game_dice", "game_result"], limit=20)
        await show_games_menu(callback.message, user_id)
        return

    if data == "game:bet":
        await callback.answer()
        await safe_edit_or_answer(callback.message, await game_bet_menu_text(user_id), reply_markup=await game_bet_menu_kb(user_id))
        return

    if data.startswith("game:bet:"):
        raw = data.split(":", 2)[2].replace(",", ".")
        try:
            value = float(raw)
            if value <= 0:
                raise ValueError
        except Exception:
            await callback.answer("Некорректная ставка", show_alert=True)
            return
        await set_user_game_bet(user_id, value)
        await callback.answer("Ставка обновлена")
        await safe_edit_or_answer(callback.message, await game_bet_menu_text(user_id), reply_markup=await game_bet_menu_kb(user_id))
        return

    if data.startswith("game:play:"):
        await play_game(callback, data.split(":", 2)[2])
        return

    # Backward compatibility for old callbacks: game:slots, game:dice, ...
    await play_game(callback, data.split(":", 1)[1])




@router.message(Command("promo"))
async def promo_cmd(message: Message) -> None:
    parts = (message.text or "").split(maxsplit=1)
    if len(parts) < 2:
        await animated_answer(message, f"{ce('tag', '🏷')} <b>Промокод</b>\n\n<i>Отправь команду так:</i> <code>/promo КОД</code>")
        return
    code = parts[1].strip().upper()
    async with await db() as conn:
        cur = await conn.execute("SELECT * FROM promocodes WHERE code=? AND is_active=1", (code,))
        promo = await cur.fetchone()
        if not promo:
            await animated_answer(message, f"{ce('cross', '❌')} <b>Промокод не найден</b>\n\n<i>Проверь код и попробуй ещё раз.</i>")
            return
        if int(promo["activations"]) >= int(promo["max_activations"]):
            await animated_answer(message, f"{ce('clock', '⏰')} <b>Лимит исчерпан</b>\n\n<i>Этот промокод уже активировали максимальное количество раз.</i>")
            return
        try:
            await conn.execute("BEGIN IMMEDIATE")
            cur_limit = await conn.execute("SELECT activations, max_activations FROM promocodes WHERE code=? AND is_active=1", (code,))
            locked_promo = await cur_limit.fetchone()
            if not locked_promo or int(locked_promo["activations"]) >= int(locked_promo["max_activations"]):
                await conn.commit()
                await animated_answer(message, f"{ce('clock', '⏰')} <b>Лимит исчерпан</b>\n\n<i>Этот промокод уже активировали максимальное количество раз.</i>")
                return
            await conn.execute("INSERT INTO promo_activations(code,user_id,created_at) VALUES(?,?,?)", (code, message.from_user.id, now_iso()))
            await conn.execute("UPDATE promocodes SET activations=activations+1 WHERE code=?", (code,))
            await conn.execute("UPDATE users SET balance=balance+? WHERE id=?", (promo["amount"], message.from_user.id))
            await conn.commit()
        except aiosqlite.IntegrityError:
            await conn.rollback()
            await animated_answer(message, f"{ce('info', 'ℹ')} <b>Промокод уже использован</b>\n\n<i>Один код можно активировать только один раз.</i>")
            return
    invalidate_user_cache(message.from_user.id)
    await animated_answer(message, f"{ce('check', '✅')} <b>Промокод активирован</b>\n\nНачислено: <b>{fmt_amount(float(promo['amount']))}⭐</b>")




# ---------------- Reward checks (deep-link bonuses) ----------------
CHECK_START_PREFIXES = ("check_", "chk_", "cheque_", "chek_")
CHECK_CODE_RE = re.compile(r"^[A-Z0-9]{4,32}$")


def normalize_reward_check_code(value: str | None) -> str:
    value = str(value or "").strip().upper()
    value = re.sub(r"[^A-Z0-9]", "", value)
    return value[:32]


def parse_reward_check_payload(payload: str | None) -> str | None:
    value = str(payload or "").strip()
    lowered = value.lower()
    for prefix in CHECK_START_PREFIXES:
        if lowered.startswith(prefix):
            code = normalize_reward_check_code(value[len(prefix):])
            return code if CHECK_CODE_RE.match(code) else None
    return None


def generate_reward_check_code(length: int = 10) -> str:
    alphabet = string.ascii_uppercase + string.digits
    return "".join(random.choices(alphabet, k=max(6, min(length, 24))))


async def build_reward_check_link(bot: Bot, code: str) -> str:
    payload = f"check_{normalize_reward_check_code(code)}"
    try:
        me = await bot.get_me()
        username = getattr(me, "username", None)
        if username:
            return f"https://t.me/{username}?start={payload}"
    except Exception:
        pass
    return f"/start {payload}"


async def store_pending_reward_check(user_id: int, code: str) -> None:
    code = normalize_reward_check_code(code)
    if not code:
        return
    async with await db() as conn:
        await conn.execute(
            "INSERT INTO pending_reward_checks(user_id,code,created_at) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET code=excluded.code, created_at=excluded.created_at",
            (int(user_id), code, now_iso()),
        )
        await conn.commit()


async def pop_pending_reward_check(user_id: int) -> str | None:
    async with await db() as conn:
        cur = await conn.execute("SELECT code FROM pending_reward_checks WHERE user_id=?", (int(user_id),))
        row = await cur.fetchone()
        await conn.execute("DELETE FROM pending_reward_checks WHERE user_id=?", (int(user_id),))
        await conn.commit()
    return normalize_reward_check_code(row["code"]) if row else None


async def activate_reward_check(user_id: int, code: str) -> tuple[bool, str]:
    code = normalize_reward_check_code(code)
    if not code or not CHECK_CODE_RE.match(code):
        return False, f"{ce('cross', '❌')} <b>Чек не найден</b>\n\n<i>Ссылка повреждена или чек уже удалён.</i>"

    amount = 0.0
    async with await db() as conn:
        try:
            await conn.execute("BEGIN IMMEDIATE")
            cur = await conn.execute("SELECT * FROM reward_checks WHERE code=? AND is_active=1", (code,))
            check = await cur.fetchone()
            if not check:
                await conn.commit()
                return False, f"{ce('cross', '❌')} <b>Чек не найден</b>\n\n<i>Ссылка повреждена, чек отключён или уже удалён.</i>"

            if int(check["activations"] or 0) >= int(check["max_activations"] or 0):
                await conn.commit()
                return False, f"{ce('clock', '⏰')} <b>Лимит чека исчерпан</b>\n\n<i>Этот чек уже активировали максимальное количество раз.</i>"

            amount = float(check["amount"] or 0)
            if amount <= 0:
                await conn.commit()
                return False, f"{ce('cross', '❌')} <b>Чек недоступен</b>\n\n<i>В чеке указана некорректная награда.</i>"

            await conn.execute(
                "INSERT INTO reward_check_activations(code,user_id,amount,created_at) VALUES(?,?,?,?)",
                (code, int(user_id), amount, now_iso()),
            )
            cur_update = await conn.execute(
                "UPDATE reward_checks SET activations=activations+1 WHERE code=? AND is_active=1 AND activations < max_activations",
                (code,),
            )
            if cur_update.rowcount != 1:
                await conn.rollback()
                return False, f"{ce('clock', '⏰')} <b>Лимит чека исчерпан</b>\n\n<i>Этот чек уже активировали максимальное количество раз.</i>"
            await conn.execute("UPDATE users SET balance=balance+? WHERE id=?", (amount, int(user_id)))
            await conn.commit()
        except aiosqlite.IntegrityError:
            await conn.rollback()
            return False, f"{ce('info', 'ℹ')} <b>Чек уже активирован</b>\n\n<i>Один чек можно активировать только один раз на аккаунт.</i>"
        except Exception as e:
            await conn.rollback()
            log.warning("reward check activation failed: %s", e)
            return False, f"{ce('cross', '❌')} <b>Не удалось активировать чек</b>\n\n<i>Попробуйте ещё раз чуть позже.</i>"

    invalidate_user_cache(int(user_id))
    return True, f"{ce('check', '✅')} <b>Чек активирован</b>\n\nНачислено: <b>{star_amount(amount)}</b>"


async def consume_pending_reward_check(user_id: int) -> str | None:
    code = await pop_pending_reward_check(int(user_id))
    if not code:
        return None
    _, text = await activate_reward_check(int(user_id), code)
    return text


async def fetch_reward_checks(limit: int = 10) -> list[Any]:
    async with await db() as conn:
        cur = await conn.execute(
            "SELECT * FROM reward_checks ORDER BY created_at DESC LIMIT ?",
            (max(1, min(int(limit), 50)),),
        )
        return await cur.fetchall()


async def reward_checks_admin_text(bot: Bot | None = None) -> str:
    rows = await fetch_reward_checks(10)
    lines = [
        f"{ce('gift', '🎁')} <b>Чеки</b>",
        "",
        "<blockquote>Чек — это одноразовая ссылка с наградой и лимитом активаций. Пользователь открывает ссылку, проходит ОП при необходимости и получает звёзды.</blockquote>",
        "",
        "<b>Создать чек:</b>",
        "<code>AMOUNT MAX</code> — код сгенерируется автоматически",
        "<code>CODE AMOUNT MAX</code> — свой код",
        "",
        "<i>Пример:</i> <code>0.5 100</code>",
        "",
        f"{ce('stats', '📊')} <b>Последние чеки</b>",
    ]
    if not rows:
        lines.append("Пока чеков нет.")
        return "\n".join(lines)
    for r in rows:
        code = str(r["code"])
        active = "✅" if int(r["is_active"] or 0) else "❌"
        left = max(0, int(r["max_activations"] or 0) - int(r["activations"] or 0))
        lines.append(
            f"• {active} <code>{html.escape(code)}</code> · {star_amount(float(r['amount'] or 0))} · "
            f"{int(r['activations'] or 0)}/{int(r['max_activations'] or 0)} · осталось {left}"
        )
    return "\n".join(lines)


def reward_checks_admin_kb(rows: list[Any] | None = None) -> InlineKeyboardMarkup:
    rows = rows or []
    keyboard: list[list[InlineKeyboardButton]] = []
    for r in rows[:8]:
        code = str(r["code"])
        keyboard.append([
            ibtn(f"{code} · {int(r['activations'] or 0)}/{int(r['max_activations'] or 0)}", callback_data=f"check:view:{code}", icon="gift"),
        ])
    keyboard.append([ibtn("Обновить", callback_data="admin:checks", icon="loading"), ibtn("Маркетинг", callback_data="admin:section:marketing", icon="back")])
    return InlineKeyboardMarkup(inline_keyboard=keyboard)


async def reward_check_detail_text(code: str, bot: Bot | None = None) -> str:
    code = normalize_reward_check_code(code)
    async with await db() as conn:
        cur = await conn.execute("SELECT * FROM reward_checks WHERE code=?", (code,))
        r = await cur.fetchone()
    if not r:
        return f"{ce('cross', '❌')} <b>Чек не найден</b>"
    link = await build_reward_check_link(bot, code) if bot is not None else f"/start check_{code}"
    active = "✅ активен" if int(r["is_active"] or 0) else "❌ выключен"
    left = max(0, int(r["max_activations"] or 0) - int(r["activations"] or 0))
    return "\n".join([
        f"{ce('gift', '🎁')} <b>Чек <code>{html.escape(code)}</code></b>",
        "",
        f"<b>Статус:</b> {active}",
        f"<b>Награда:</b> {star_amount(float(r['amount'] or 0))}",
        f"<b>Активации:</b> {int(r['activations'] or 0)}/{int(r['max_activations'] or 0)}",
        f"<b>Осталось:</b> {left}",
        f"<b>Создан:</b> {html.escape(str(r['created_at'] or '—'))}",
        "",
        f"<b>Ссылка:</b> <code>{html.escape(link)}</code>",
    ])


def reward_check_detail_kb(code: str, is_active: bool = True) -> InlineKeyboardMarkup:
    code = normalize_reward_check_code(code)
    toggle_text = "Выключить" if is_active else "Включить"
    toggle_icon = "trash" if is_active else "check"
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn(toggle_text, callback_data=f"check:toggle:{code}", icon=toggle_icon)],
        [ibtn("Все чеки", callback_data="admin:checks", icon="back")],
    ])

async def build_profile_text(user_id: int) -> str:
    row = await get_user(user_id)
    if not row:
        return ce("profile", "👤") + " <b>Профиль не найден</b>\n\n<i>Нажмите /start, чтобы зарегистрироваться в боте.</i>"

    username = f"@{row['username']}" if row["username"] else "—"
    created_at = row["created_at"] or "—"
    values = {
        "user_id": user_id,
        "first_name": html.escape(row["first_name"] or "—"),
        "username": html.escape(username),
        "balance": fmt_amount(float(row["balance"] or 0)),
        "invited": int(row["invited_count"] or 0),
        "is_op_passed": "✅ да" if row["is_op_passed"] else "❌ нет",
        "created_at": html.escape(created_at),
        "currency_name": html.escape(await get_setting("currency_name", "звёзды")),
    }
    template = await get_setting("profile_text", str(DEFAULT_SETTINGS["profile_text"]))
    try:
        return template.format(**values)
    except Exception as e:
        return template + f"\n\n⚠️ Ошибка в шаблоне профиля: {html.escape(str(e))}"


@router.message()
async def dynamic_main_menu_buttons(message: Message) -> None:
    text = (message.text or "").strip()
    if not text:
        return

    profile_button = clean_button_text(await get_setting("profile_button_text", str(DEFAULT_SETTINGS["profile_button_text"])))
    buy_button = clean_button_text(await get_setting("buy_stars_button_text", str(DEFAULT_SETTINGS["buy_stars_button_text"])))
    admin_button = clean_button_text(await get_setting("admin_panel_button_text", str(DEFAULT_SETTINGS["admin_panel_button_text"])))

    if text == profile_button:
        await cleanup_general_flow(message, message.from_user.id if message.from_user else None)
        await upsert_user(message)
        await animated_answer(message, await build_profile_text(message.from_user.id), track_scope="menu")
        return

    if text == buy_button and await get_setting("buy_stars_button_enabled", "1") == "1":
        await cleanup_general_flow(message, message.from_user.id if message.from_user else None)
        await animated_answer(message, await get_setting("buy_stars_text"), track_scope="menu")
        return

    if text == admin_button and await is_admin(message.from_user.id):
        await animated_answer(message, await admin_dashboard_text(), reply_markup=admin_menu(), parse_mode=ParseMode.HTML)
        return



class AdminStates(StatesGroup):
    broadcast = State()
    promo = State()
    check = State()
    link = State()
    user_search = State()
    user_balance = State()
    setting_key = State()
    setting_value = State()


@admin_router.message(Command("admin"))
async def admin_start(message: Message) -> None:
    if not await is_admin(message.from_user.id):
        return
    await animated_answer(message, await admin_dashboard_text(), reply_markup=admin_menu(), parse_mode=ParseMode.HTML)




async def log_admin_action(admin_id: int, user_id: int, action: str, details: str = "") -> None:
    async with await db() as conn:
        await conn.execute(
            "INSERT INTO admin_action_logs(admin_id,user_id,action,details,created_at) VALUES(?,?,?,?,?)",
            (admin_id, user_id, action, details[:1000], now_iso()),
        )
        await conn.commit()


async def find_users(query: str) -> list[aiosqlite.Row]:
    q = (query or "").strip()
    if not q:
        return []
    if q.startswith("@"):
        q = q[1:]
    async with await db() as conn:
        if q.isdigit():
            cur = await conn.execute("SELECT * FROM users WHERE id=? LIMIT 20", (int(q),))
        else:
            like = f"%{q}%"
            cur = await conn.execute(
                """
                SELECT * FROM users
                WHERE username LIKE ? OR first_name LIKE ? OR source_code LIKE ?
                ORDER BY last_seen DESC LIMIT 20
                """,
                (like, like, like),
            )
        return await cur.fetchall()


async def admin_users_home_text() -> str:
    async with await db() as conn:
        cur = await conn.execute("SELECT COUNT(*) c FROM users")
        total = (await cur.fetchone())["c"]
        cur = await conn.execute("SELECT COUNT(*) c FROM users WHERE is_banned=1")
        banned = (await cur.fetchone())["c"]
        cur = await conn.execute("SELECT COUNT(*) c FROM users WHERE is_op_passed=1")
        op = (await cur.fetchone())["c"]
        cur = await conn.execute("SELECT COUNT(*) c FROM users WHERE last_seen >= ?", ((datetime.now(timezone.utc) - timedelta(days=1)).isoformat(timespec="seconds"),))
        active24 = (await cur.fetchone())["c"]
    return (
        f"{ce('people', '👥')} <b>Пользователи</b>\n\n"
        f"Всего: <b>{total}</b>\n"
        f"Активны за 24ч: <b>{active24}</b>\n"
        f"Прошли ОП: <b>{op}</b>\n"
        f"Забанены: <b>{banned}</b>\n\n"
        "Нажмите «Найти пользователя» и отправьте ID, @username, имя или UTM/source."
    )


def admin_users_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Найти пользователя", callback_data="users:search", icon="people")],
        [ibtn("Последние 10", callback_data="users:latest", icon="clock"), ibtn("Забаненные", callback_data="users:banned", icon="lock")],
        [ibtn("Админка", callback_data="admin:menu", icon="home")],
    ])


def users_list_kb(rows: list[aiosqlite.Row], back_callback: str = "admin:users") -> InlineKeyboardMarkup:
    keyboard = []
    for row in rows[:10]:
        username = f"@{row['username']}" if row["username"] else (row["first_name"] or "без имени")
        status = "BAN" if row["is_banned"] else ("OP" if row["is_op_passed"] else "NEW")
        keyboard.append([ibtn(f"{row['id']} · {username} · {status}", callback_data=f"user:card:{row['id']}", icon="profile")])
    keyboard.append([ibtn("Назад", callback_data=back_callback, icon="back"), ibtn("Админка", callback_data="admin:menu", icon="home")])
    return InlineKeyboardMarkup(inline_keyboard=keyboard)


async def latest_users(limit: int = 10, banned_only: bool = False) -> list[aiosqlite.Row]:
    async with await db() as conn:
        if banned_only:
            cur = await conn.execute("SELECT * FROM users WHERE is_banned=1 ORDER BY last_seen DESC LIMIT ?", (limit,))
        else:
            cur = await conn.execute("SELECT * FROM users ORDER BY created_at DESC LIMIT ?", (limit,))
        return await cur.fetchall()


async def admin_user_card_text(user_id: int) -> str:
    row = await get_user(user_id)
    if not row:
        return f"{ce('cross', '❌')} Пользователь <code>{user_id}</code> не найден."
    username = f"@{row['username']}" if row["username"] else "—"
    status = f"{ce('lock', '🔒')} забанен" if row["is_banned"] else f"{ce('unlock', '🔓')} активен"
    op_status = f"{ce('check', '✅')} да" if row["is_op_passed"] else f"{ce('cross', '❌')} нет"
    async with await db() as conn:
        cur = await conn.execute("SELECT COUNT(*) c FROM withdraw_requests WHERE user_id=? AND status='pending'", (user_id,))
        pending_wd = (await cur.fetchone())["c"]
        cur = await conn.execute("SELECT COALESCE(SUM(amount),0) s FROM withdraw_requests WHERE user_id=?", (user_id,))
        wd_sum = float((await cur.fetchone())["s"] or 0)
        cur = await conn.execute("SELECT COUNT(*) c FROM task_logs WHERE user_id=? AND status='done'", (user_id,))
        tasks_done = (await cur.fetchone())["c"]
        cur = await conn.execute("SELECT * FROM task_sessions WHERE user_id=?", (user_id,))
        task = await cur.fetchone()
    task_line = "нет"
    if task:
        task_line = f"{task['service']} · {task['status']} · №{task['task_num']}"
    lines = [
        f"{ce('profile', '👤')} <b>Карточка пользователя</b>",
        "",
        f"ID: <code>{user_id}</code>",
        f"Имя: <b>{html.escape(row['first_name'] or '—')}</b>",
        f"Username: <code>{html.escape(username)}</code>",
        f"Статус: {status}",
        f"Баланс: <b>{fmt_amount(float(row['balance'] or 0))}⭐</b>",
        f"ОП пройдена: {op_status}",
        f"Реферер: <code>{html.escape(str(row['referrer_id'] or '—'))}</code>",
        f"Приглашено: <b>{int(row['invited_count'] or 0)}</b>",
        f"Источник: <code>{html.escape(row['source_code'] or 'direct')}</code>",
        f"Создан: <code>{html.escape(row['created_at'] or '—')}</code>",
        f"Последний визит: <code>{html.escape(row['last_seen'] or '—')}</code>",
        "",
        f"Выполнено заданий: <b>{tasks_done}</b>",
        f"Активное задание: <code>{html.escape(task_line)}</code>",
        f"Pending выводов: <b>{pending_wd}</b>",
        f"Всего выводов на: <b>{fmt_amount(wd_sum)}⭐</b>",
    ]
    return "\n".join(lines)[:3900]


async def admin_user_card_kb(user_id: int) -> InlineKeyboardMarkup:
    row = await get_user(user_id)
    banned = bool(row and row["is_banned"])
    op_passed = bool(row and row["is_op_passed"])
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Изменить баланс", callback_data=f"user:balance:{user_id}", icon="money"), ibtn("История", callback_data=f"user:history:{user_id}", icon="file")],
        [ibtn("Разбанить" if banned else "Забанить", callback_data=f"user:ban:{user_id}", icon="unlock" if banned else "lock")],
        [ibtn("Сбросить ОП" if op_passed else "Отметить ОП", callback_data=f"user:op:{user_id}", icon="user_no" if op_passed else "user_ok")],
        [ibtn("Сбросить задание", callback_data=f"user:taskreset:{user_id}", icon="trash")],
        [ibtn("Обновить", callback_data=f"user:card:{user_id}", icon="loading"), ibtn("К поиску", callback_data="admin:users", icon="back")],
    ])


async def admin_user_history_text(user_id: int) -> str:
    row = await get_user(user_id)
    if not row:
        return f"{ce('cross', '❌')} Пользователь не найден."
    lines = [f"{ce('file', '📁')} <b>История пользователя</b> <code>{user_id}</code>", ""]
    async with await db() as conn:
        sections = [
            ("Задания", "SELECT service, reward, status, created_at FROM task_logs WHERE user_id=? ORDER BY id DESC LIMIT 5"),
            ("Выводы", "SELECT amount, status, created_at FROM withdraw_requests WHERE user_id=? ORDER BY id DESC LIMIT 5"),
            ("Бонусы", "SELECT amount, created_at FROM bonus_logs WHERE user_id=? ORDER BY id DESC LIMIT 5"),
            ("Игры", "SELECT game, bet, win, result, created_at FROM game_logs WHERE user_id=? ORDER BY id DESC LIMIT 5"),
            ("Промокоды", "SELECT code, created_at FROM promo_activations WHERE user_id=? ORDER BY id DESC LIMIT 5"),
            ("Действия админов", "SELECT admin_id, action, details, created_at FROM admin_action_logs WHERE user_id=? ORDER BY id DESC LIMIT 5"),
        ]
        for title, sql in sections:
            lines.append(f"<b>{html.escape(title)}</b>")
            cur = await conn.execute(sql, (user_id,))
            rows = await cur.fetchall()
            if not rows:
                lines.append("—")
            else:
                for r in rows:
                    d = dict(r)
                    created = html.escape(str(d.pop("created_at", "—")))
                    body = "; ".join(f"{html.escape(str(k))}={html.escape(str(v))}" for k, v in d.items())
                    lines.append(f"• <code>{created}</code> · {body}")
            lines.append("")
    return "\n".join(lines)[:3900]


@admin_router.callback_query(F.data == "admin:users")
async def admin_users(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    await safe_edit_or_answer(callback.message, await admin_users_home_text(), reply_markup=admin_users_kb(), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data == "users:search")
async def admin_users_search_start(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.set_state(AdminStates.user_search)
    await animated_answer(callback.message, "Отправьте ID, @username, имя или UTM/source пользователя.", reply_markup=InlineKeyboardMarkup(inline_keyboard=[[ibtn("Отмена", callback_data="admin:users", icon="cancel")]]))
    await callback.answer()


@admin_router.message(AdminStates.user_search)
async def admin_users_search_run(message: Message, state: FSMContext) -> None:
    if not await is_admin(message.from_user.id): return
    rows = await find_users(message.text or "")
    await state.clear()
    if not rows:
        await animated_answer(message, f"{ce('cross', '❌')} Пользователи не найдены.", reply_markup=admin_users_kb())
        return
    if len(rows) == 1:
        user_id = int(rows[0]["id"])
        await animated_answer(message, await admin_user_card_text(user_id), reply_markup=await admin_user_card_kb(user_id), parse_mode=ParseMode.HTML)
        return
    await animated_answer(message, f"{ce('people', '👥')} Найдено: {len(rows)}. Выберите пользователя:", reply_markup=users_list_kb(rows), parse_mode=ParseMode.HTML)


@admin_router.callback_query(F.data == "users:latest")
async def admin_users_latest(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    rows = await latest_users(10, banned_only=False)
    await safe_edit_or_answer(callback.message, f"{ce('clock', '⏰')} Последние пользователи", reply_markup=users_list_kb(rows), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data == "users:banned")
async def admin_users_banned(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    rows = await latest_users(10, banned_only=True)
    if not rows:
        await safe_edit_or_answer(callback.message, f"{ce('unlock', '🔓')} Забаненных пользователей нет.", reply_markup=admin_users_kb(), parse_mode=ParseMode.HTML)
    else:
        await safe_edit_or_answer(callback.message, f"{ce('lock', '🔒')} Забаненные пользователи", reply_markup=users_list_kb(rows), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data.startswith("user:card:"))
async def admin_user_card(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    user_id = int(callback.data.split(":", 2)[2])
    await safe_edit_or_answer(callback.message, await admin_user_card_text(user_id), reply_markup=await admin_user_card_kb(user_id), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data.startswith("user:history:"))
async def admin_user_history(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    user_id = int(callback.data.split(":", 2)[2])
    kb = InlineKeyboardMarkup(inline_keyboard=[[ibtn("Назад", callback_data=f"user:card:{user_id}", icon="back")]])
    await safe_edit_or_answer(callback.message, await admin_user_history_text(user_id), reply_markup=kb, parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data.startswith("user:balance:"))
async def admin_user_balance_start(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    user_id = int(callback.data.split(":", 2)[2])
    if not await get_user(user_id):
        await callback.answer("Пользователь не найден", show_alert=True)
        return
    await state.set_state(AdminStates.user_balance)
    await state.update_data(user_id=user_id)
    text = (
        "Отправьте изменение баланса одним сообщением:\n\n"
        "<code>+1.5</code> — начислить\n"
        "<code>-2</code> — списать\n"
        "<code>=10</code> — установить точный баланс"
    )
    await animated_answer(callback.message, text, reply_markup=InlineKeyboardMarkup(inline_keyboard=[[ibtn("Отмена", callback_data=f"user:card:{user_id}", icon="cancel")]]), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.message(AdminStates.user_balance)
async def admin_user_balance_save(message: Message, state: FSMContext) -> None:
    if not await is_admin(message.from_user.id): return
    data = await state.get_data()
    user_id = int(data.get("user_id", 0))
    row = await get_user(user_id)
    if not row:
        await state.clear()
        await animated_answer(message, "Пользователь не найден.")
        return
    raw = (message.text or "").strip().replace(",", ".")
    try:
        if raw.startswith("="):
            new_balance = float(raw[1:])
            delta = new_balance - float(row["balance"] or 0)
            details = f"set balance to {fmt_amount(new_balance)}"
        else:
            delta = float(raw)
            new_balance = float(row["balance"] or 0) + delta
            details = f"delta {fmt_amount(delta)}; balance {fmt_amount(new_balance)}"
    except Exception:
        await animated_answer(message, "Введите число в формате +1.5, -2 или =10.")
        return
    async with await db() as conn:
        await conn.execute("UPDATE users SET balance=? WHERE id=?", (new_balance, user_id))
        await conn.commit()
    invalidate_user_cache(user_id)
    await log_admin_action(message.from_user.id, user_id, "balance", details)
    await state.clear()
    await animated_answer(message, f"{ce('check', '✅')} <b>Баланс обновлён</b>\n\nНовое значение: <b>{fmt_amount(new_balance)}⭐</b>")
    await animated_answer(message, await admin_user_card_text(user_id), reply_markup=await admin_user_card_kb(user_id), parse_mode=ParseMode.HTML)


@admin_router.callback_query(F.data.startswith("user:ban:"))
async def admin_user_toggle_ban(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    user_id = int(callback.data.split(":", 2)[2])
    row = await get_user(user_id)
    if not row:
        await callback.answer("Пользователь не найден", show_alert=True)
        return
    new_value = 0 if row["is_banned"] else 1
    async with await db() as conn:
        await conn.execute("UPDATE users SET is_banned=? WHERE id=?", (new_value, user_id))
        await conn.commit()
    invalidate_user_cache(user_id)
    await log_admin_action(callback.from_user.id, user_id, "ban" if new_value else "unban", "")
    await safe_edit_or_answer(callback.message, await admin_user_card_text(user_id), reply_markup=await admin_user_card_kb(user_id), parse_mode=ParseMode.HTML)
    await callback.answer("Готово")


@admin_router.callback_query(F.data.startswith("user:op:"))
async def admin_user_toggle_op(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    user_id = int(callback.data.split(":", 2)[2])
    row = await get_user(user_id)
    if not row:
        await callback.answer("Пользователь не найден", show_alert=True)
        return
    new_value = 0 if row["is_op_passed"] else 1
    async with await db() as conn:
        if new_value:
            await conn.execute("UPDATE users SET is_op_passed=1, op_passed_at=? WHERE id=?", (now_iso(), user_id))
        else:
            await conn.execute("UPDATE users SET is_op_passed=0, op_passed_at=NULL WHERE id=?", (user_id,))
        await conn.commit()
    invalidate_user_cache(user_id)
    _invalidate_op_gate_cache(user_id)
    await log_admin_action(callback.from_user.id, user_id, "op_pass" if new_value else "op_reset", "")
    await safe_edit_or_answer(callback.message, await admin_user_card_text(user_id), reply_markup=await admin_user_card_kb(user_id), parse_mode=ParseMode.HTML)
    await callback.answer("Готово")


@admin_router.callback_query(F.data.startswith("user:taskreset:"))
async def admin_user_task_reset(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    user_id = int(callback.data.split(":", 2)[2])
    async with await db() as conn:
        await conn.execute("DELETE FROM task_sessions WHERE user_id=?", (user_id,))
        await conn.commit()
    await log_admin_action(callback.from_user.id, user_id, "task_reset", "active task session deleted")
    await safe_edit_or_answer(callback.message, await admin_user_card_text(user_id), reply_markup=await admin_user_card_kb(user_id), parse_mode=ParseMode.HTML)
    await callback.answer("Задание сброшено")


@admin_router.callback_query(F.data.startswith("admin:section:"))
async def admin_section_callback(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    section = callback.data.split(":", 2)[2]
    await safe_edit_or_answer(callback.message, await admin_section_text(section), reply_markup=admin_section_kb(section), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data == "admin:stats")
async def admin_stats(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    async with await db() as conn:
        q = {}
        for name, sql in {
            "users": "SELECT COUNT(*) c FROM users",
            "op": "SELECT COUNT(*) c FROM users WHERE is_op_passed=1",
            "tasks": "SELECT COUNT(*) c FROM task_logs WHERE status='done'",
            "withdraws": "SELECT COUNT(*) c FROM withdraw_requests WHERE status='pending'",
            "balance": "SELECT COALESCE(SUM(balance),0) c FROM users",
        }.items():
            cur = await conn.execute(sql)
            q[name] = (await cur.fetchone())["c"]
    await safe_edit_or_answer(
        callback.message,
        f"👥 Пользователей: {q['users']}\n"
        f"✅ Прошли ОП: {q['op']}\n"
        f"💎 Выполнено заданий: {q['tasks']}\n"
        f"💸 Заявок на вывод: {q['withdraws']}\n"
        f"⭐ Баланс у пользователей: {fmt_amount(float(q['balance']))}",
        reply_markup=admin_menu(),
        parse_mode=ParseMode.HTML,
    )
    await callback.answer()



def utm_safe_code_from_callback(data: str, prefix: str) -> str:
    return data[len(prefix):].strip()[:80]


def utm_list_kb(rows: list[Any]) -> InlineKeyboardMarkup:
    kb_rows: list[list[InlineKeyboardButton]] = []
    for row in rows[:50]:
        code = str(row["code"])
        users = int(row["users"] or 0)
        op = int(row["op"] or 0)
        conv = (op / users * 100) if users else 0
        title = f"{code} · {users} юз · {conv:.0f}% ОП"
        kb_rows.append([ibtn(title, callback_data=f"utm:view:{code}", icon="growth")])
    kb_rows.append([ibtn("Создать UTM", callback_data="admin:create_link", icon="link")])
    kb_rows.append([ibtn("Маркетинг", callback_data="admin:section:marketing", icon="growth"), ibtn("Обзор", callback_data="admin:menu", icon="home")])
    return InlineKeyboardMarkup(inline_keyboard=kb_rows)


async def fetch_utm_rows(limit: int = 50) -> list[Any]:
    async with await db() as conn:
        cur = await conn.execute(
            """
            SELECT l.code, l.title, l.created_at,
                   COUNT(u.id) AS users,
                   COALESCE(SUM(CASE WHEN u.is_op_passed=1 THEN 1 ELSE 0 END), 0) AS op,
                   COALESCE(SUM(CASE WHEN u.created_at >= datetime('now','-1 day') THEN 1 ELSE 0 END), 0) AS day_users,
                   COALESCE(SUM(CASE WHEN u.created_at >= datetime('now','-7 day') THEN 1 ELSE 0 END), 0) AS week_users,
                   MAX(u.created_at) AS last_user_at
            FROM utm_links l
            LEFT JOIN users u ON u.source_code = l.code
            LEFT JOIN utm_deleted_links d ON d.code = l.code
            WHERE d.code IS NULL
            GROUP BY l.code, l.title, l.created_at
            ORDER BY users DESC, l.created_at DESC
            LIMIT ?
            """,
            (int(limit),),
        )
        return await cur.fetchall()


async def utm_summary_text(rows: list[Any]) -> str:
    total_links = len(rows)
    total_users = sum(int(r["users"] or 0) for r in rows)
    total_op = sum(int(r["op"] or 0) for r in rows)
    conv = (total_op / total_users * 100) if total_users else 0
    lines = [
        f"{ce('growth', '📊')} <b>UTM-ссылки</b>",
        "",
        f"<blockquote><b>Активных ссылок:</b> {total_links}\n<b>Пользователей:</b> {total_users}\n<b>Прошли ОП:</b> {total_op} ({conv:.1f}%)</blockquote>",
        "<i>Нажмите на ссылку ниже, чтобы открыть подробную статистику или удалить её.</i>",
    ]
    if not rows:
        lines.append("\nПока нет созданных UTM-ссылок. Нажмите «Создать UTM».")
    return "\n".join(lines)


async def utm_detail_text(code: str, bot: Bot | None = None) -> str:
    async with await db() as conn:
        cur = await conn.execute("SELECT code,title,created_at FROM utm_links WHERE code=?", (code,))
        link = await cur.fetchone()
        cur = await conn.execute(
            """
            SELECT COUNT(*) users,
                   COALESCE(SUM(CASE WHEN is_op_passed=1 THEN 1 ELSE 0 END),0) op,
                   COALESCE(SUM(CASE WHEN ref_rewarded=1 THEN 1 ELSE 0 END),0) refs,
                   COALESCE(SUM(balance),0) balance,
                   COALESCE(SUM(invited_count),0) invited,
                   COALESCE(SUM(CASE WHEN created_at >= datetime('now','-1 day') THEN 1 ELSE 0 END),0) day_users,
                   COALESCE(SUM(CASE WHEN created_at >= datetime('now','-7 day') THEN 1 ELSE 0 END),0) week_users,
                   MIN(created_at) first_user_at,
                   MAX(created_at) last_user_at
            FROM users WHERE source_code=?
            """,
            (code,),
        )
        stats = await cur.fetchone()
        cur = await conn.execute("SELECT COUNT(*) c FROM task_logs WHERE user_id IN (SELECT id FROM users WHERE source_code=?) AND status='done'", (code,))
        tasks_done = (await cur.fetchone())["c"]
        cur = await conn.execute("SELECT COUNT(*) c, COALESCE(SUM(amount),0) s FROM withdraw_requests WHERE user_id IN (SELECT id FROM users WHERE source_code=?)", (code,))
        wd_all = await cur.fetchone()
        cur = await conn.execute("SELECT COUNT(*) c, COALESCE(SUM(amount),0) s FROM withdraw_requests WHERE user_id IN (SELECT id FROM users WHERE source_code=?) AND status='pending'", (code,))
        wd_pending = await cur.fetchone()
    users = int(stats["users"] or 0)
    op = int(stats["op"] or 0)
    conv = (op / users * 100) if users else 0
    link_title = link["title"] if link else code
    created_at = link["created_at"] if link else "—"
    url = ""
    if bot is not None:
        try:
            me = await bot.get_me()
            if getattr(me, "username", None):
                url = f"https://t.me/{me.username}?start={code}"
        except Exception:
            pass
    lines = [
        f"{ce('growth', '📊')} <b>UTM: <code>{html.escape(code)}</code></b>",
        "",
        f"<blockquote><b>Название:</b> {html.escape(str(link_title))}\n<b>Создана:</b> {html.escape(str(created_at))}</blockquote>",
    ]
    if url:
        lines.append(f"<b>Ссылка:</b> <code>{html.escape(url)}</code>")
    lines.extend([
        "",
        f"<b>Пользователи:</b> {users}",
        f"<b>Новые за 24ч:</b> {int(stats['day_users'] or 0)}",
        f"<b>Новые за 7д:</b> {int(stats['week_users'] or 0)}",
        f"<b>Прошли ОП:</b> {op} ({conv:.1f}%)",
        f"<b>Ref rewarded:</b> {int(stats['refs'] or 0)}",
        f"<b>Приглашений от этих пользователей:</b> {int(stats['invited'] or 0)}",
        f"<b>Баланс группы:</b> {star_amount(float(stats['balance'] or 0))}",
        "",
        f"<b>Выполнено заданий:</b> {int(tasks_done or 0)}",
        f"<b>Выводов всего:</b> {int(wd_all['c'] or 0)} на {star_amount(float(wd_all['s'] or 0))}",
        f"<b>Ожидает вывод:</b> {int(wd_pending['c'] or 0)} на {star_amount(float(wd_pending['s'] or 0))}",
        "",
        f"<i>Первый пользователь:</i> {html.escape(str(stats['first_user_at'] or '—'))}",
        f"<i>Последний пользователь:</i> {html.escape(str(stats['last_user_at'] or '—'))}",
    ])
    return "\n".join(lines)


def utm_detail_kb(code: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Пользователи по ссылке", callback_data=f"utm:users:{code}", icon="people")],
        [ibtn("Удалить UTM", callback_data=f"utm:delete:{code}", icon="trash")],
        [ibtn("Назад к UTM", callback_data="admin:utm", icon="back"), ibtn("Создать UTM", callback_data="admin:create_link", icon="link")],
    ])


@admin_router.callback_query(F.data == "admin:utm")
async def admin_utm(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    rows = await fetch_utm_rows()
    await safe_edit_or_answer(callback.message, await utm_summary_text(rows), reply_markup=utm_list_kb(rows), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data.startswith("utm:view:"))
async def admin_utm_view(callback: CallbackQuery, bot: Bot) -> None:
    if not await is_admin(callback.from_user.id): return
    code = utm_safe_code_from_callback(callback.data or "", "utm:view:")
    await safe_edit_or_answer(callback.message, await utm_detail_text(code, bot), reply_markup=utm_detail_kb(code), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data.startswith("utm:users:"))
async def admin_utm_users(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    code = utm_safe_code_from_callback(callback.data or "", "utm:users:")
    async with await db() as conn:
        cur = await conn.execute(
            """
            SELECT id, username, first_name, balance, is_op_passed, created_at, last_seen
            FROM users
            WHERE source_code=?
            ORDER BY created_at DESC
            LIMIT 20
            """,
            (code,),
        )
        rows = await cur.fetchall()
    lines = [f"{ce('people', '👥')} <b>Пользователи UTM <code>{html.escape(code)}</code></b>", ""]
    if not rows:
        lines.append("Пользователей по этой ссылке пока нет.")
    for r in rows:
        username = ("@" + r["username"]) if r["username"] else "без username"
        op = "да" if int(r["is_op_passed"] or 0) else "нет"
        lines.append(
            f"• <code>{r['id']}</code> · {html.escape(str(username))} · OP: <b>{op}</b> · {star_amount(float(r['balance'] or 0))}"
        )
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("К статистике UTM", callback_data=f"utm:view:{code}", icon="back")],
        [ibtn("Все UTM", callback_data="admin:utm", icon="growth")],
    ])
    await safe_edit_or_answer(callback.message, "\n".join(lines)[:4000], reply_markup=kb, parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data.startswith("utm:delete:"))
async def admin_utm_delete(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    code = utm_safe_code_from_callback(callback.data or "", "utm:delete:")
    text = (
        f"{ce('trash', '🗑')} <b>Удалить UTM <code>{html.escape(code)}</code>?</b>\n\n"
        "<blockquote>Ссылка исчезнет из списка UTM и будет добавлена в стоп-лист, чтобы бот не пересоздал её автоматически при следующем переходе.</blockquote>\n\n"
        "<i>История пользователей сохранится в базе: их source_code не меняется.</i>"
    )
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [ibtn("Да, удалить", callback_data=f"utm:delete_confirm:{code}", icon="trash")],
        [ibtn("Отмена", callback_data=f"utm:view:{code}", icon="back")],
    ])
    await safe_edit_or_answer(callback.message, text, reply_markup=kb, parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data.startswith("utm:delete_confirm:"))
async def admin_utm_delete_confirm(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    code = utm_safe_code_from_callback(callback.data or "", "utm:delete_confirm:")
    async with await db() as conn:
        await conn.execute("DELETE FROM utm_links WHERE code=?", (code,))
        await conn.execute(
            "INSERT INTO utm_deleted_links(code,deleted_by,deleted_at) VALUES(?,?,?) ON CONFLICT(code) DO UPDATE SET deleted_by=excluded.deleted_by, deleted_at=excluded.deleted_at",
            (code, callback.from_user.id, now_iso()),
        )
        await conn.commit()
    rows = await fetch_utm_rows()
    await safe_edit_or_answer(
        callback.message,
        f"{ce('check', '✅')} <b>UTM <code>{html.escape(code)}</code> удалена</b>\n\n" + await utm_summary_text(rows),
        reply_markup=utm_list_kb(rows),
        parse_mode=ParseMode.HTML,
    )
    await callback.answer("UTM удалена")


@admin_router.callback_query(F.data == "admin:broadcast")
async def admin_broadcast(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.set_state(AdminStates.broadcast)
    await animated_answer(callback.message, f"{ce('broadcast', '📣')} <b>Рассылка</b>\n\n<i>Отправьте сообщение, которое нужно разослать пользователям. Форматирование Telegram сохранится.</i>")
    await callback.answer()


@admin_router.message(AdminStates.broadcast)
async def admin_broadcast_run(message: Message, state: FSMContext, bot: Bot) -> None:
    if not await is_admin(message.from_user.id): return
    await state.clear()
    async with await db() as conn:
        cur = await conn.execute("SELECT id FROM users WHERE is_banned=0")
        ids = [r["id"] for r in await cur.fetchall()]
    ok = bad = 0
    await animated_answer(message, f"{ce('send', '⬆')} <b>Рассылка запущена</b>\n\nПолучателей: <b>{len(ids)}</b>")
    for uid in ids:
        try:
            await bot.send_message(uid, message.html_text or message.text or "")
            ok += 1
            await asyncio.sleep(0.04)
        except (TelegramForbiddenError, TelegramBadRequest):
            bad += 1
        except Exception:
            bad += 1
    await animated_answer(message, f"{ce('check', '✅')} <b>Рассылка завершена</b>\n\nОтправлено: <b>{ok}</b>\nОшибок: <b>{bad}</b>")


@admin_router.callback_query(F.data == "admin:promos")
async def admin_promos(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.set_state(AdminStates.promo)
    await animated_answer(callback.message, f"{ce('tag', '🏷')} <b>Создание промокода</b>\n\n<i>Отправьте данные в формате:</i>\n<code>CODE AMOUNT MAX</code>\n\n<blockquote>Например: <code>START 0.5 100</code></blockquote>", parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.message(AdminStates.promo)
async def admin_promo_save(message: Message, state: FSMContext) -> None:
    if not await is_admin(message.from_user.id): return
    parts = (message.text or "").split()
    if len(parts) != 3:
        await animated_answer(message, f"{ce('info', 'ℹ')} <b>Нужно 3 значения</b>\n\n<code>CODE AMOUNT MAX</code>")
        return
    code = parts[0].upper()
    amount = float(parts[1].replace(",", "."))
    max_act = int(parts[2])
    async with await db() as conn:
        await conn.execute("INSERT INTO promocodes(code,amount,max_activations,created_at) VALUES(?,?,?,?) ON CONFLICT(code) DO UPDATE SET amount=excluded.amount,max_activations=excluded.max_activations,is_active=1", (code, amount, max_act, now_iso()))
        await conn.commit()
    await state.clear()
    await animated_answer(message, f"{ce('check', '✅')} Промокод создан: /promo {code}")




@admin_router.callback_query(F.data == "admin:checks")
async def admin_checks(callback: CallbackQuery, state: FSMContext, bot: Bot) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.set_state(AdminStates.check)
    rows = await fetch_reward_checks(10)
    await safe_edit_or_answer(
        callback.message,
        await reward_checks_admin_text(bot),
        reply_markup=reward_checks_admin_kb(rows),
        parse_mode=ParseMode.HTML,
    )
    await callback.answer()


@admin_router.message(AdminStates.check)
async def admin_check_save(message: Message, state: FSMContext, bot: Bot) -> None:
    if not await is_admin(message.from_user.id): return
    parts = (message.text or "").split()
    if len(parts) not in {2, 3}:
        await animated_answer(
            message,
            f"{ce('info', 'ℹ')} <b>Нужно 2 или 3 значения</b>\n\n"
            "<code>AMOUNT MAX</code> — код сгенерируется автоматически\n"
            "<code>CODE AMOUNT MAX</code> — свой код\n\n"
            "<i>Пример:</i> <code>0.5 100</code>",
            parse_mode=ParseMode.HTML,
        )
        return

    try:
        if len(parts) == 2:
            code = generate_reward_check_code()
            amount_raw, max_raw = parts
        else:
            code = normalize_reward_check_code(parts[0])
            amount_raw, max_raw = parts[1], parts[2]
        amount = float(amount_raw.replace(",", "."))
        max_act = int(max_raw)
        if not CHECK_CODE_RE.match(code):
            raise ValueError("bad code")
        if amount <= 0 or max_act <= 0:
            raise ValueError("bad values")
    except Exception:
        await animated_answer(message, f"{ce('cross', '❌')} <b>Некорректные данные</b>\n\n<i>Пример:</i> <code>0.5 100</code> или <code>DROP 1 50</code>")
        return

    # If the auto-generated code already exists, try a few new variants.
    async with await db() as conn:
        for _ in range(8):
            cur = await conn.execute("SELECT 1 FROM reward_checks WHERE code=?", (code,))
            exists = await cur.fetchone()
            if not exists:
                break
            if len(parts) == 3:
                await animated_answer(message, f"{ce('cross', '❌')} <b>Такой чек уже существует</b>\n\n<i>Выбери другой код.</i>")
                return
            code = generate_reward_check_code()
        await conn.execute(
            "INSERT INTO reward_checks(code,amount,max_activations,activations,is_active,created_by,created_at) VALUES(?,?,?,0,1,?,?)",
            (code, amount, max_act, int(message.from_user.id), now_iso()),
        )
        await conn.commit()

    link = await build_reward_check_link(bot, code)
    await state.clear()
    await animated_answer(
        message,
        "\n".join([
            f"{ce('check', '✅')} <b>Чек создан</b>",
            "",
            f"<b>Код:</b> <code>{html.escape(code)}</code>",
            f"<b>Награда:</b> {star_amount(amount)}",
            f"<b>Активаций:</b> {max_act}",
            "",
            f"<b>Ссылка:</b> <code>{html.escape(link)}</code>",
        ]),
        parse_mode=ParseMode.HTML,
    )


@admin_router.callback_query(F.data.startswith("check:view:"))
async def admin_check_view(callback: CallbackQuery, bot: Bot) -> None:
    if not await is_admin(callback.from_user.id): return
    code = normalize_reward_check_code((callback.data or "").split(":", 2)[2])
    async with await db() as conn:
        cur = await conn.execute("SELECT is_active FROM reward_checks WHERE code=?", (code,))
        row = await cur.fetchone()
    await safe_edit_or_answer(
        callback.message,
        await reward_check_detail_text(code, bot),
        reply_markup=reward_check_detail_kb(code, bool(row and int(row["is_active"] or 0))),
        parse_mode=ParseMode.HTML,
    )
    await callback.answer()


@admin_router.callback_query(F.data.startswith("check:toggle:"))
async def admin_check_toggle(callback: CallbackQuery, bot: Bot) -> None:
    if not await is_admin(callback.from_user.id): return
    code = normalize_reward_check_code((callback.data or "").split(":", 2)[2])
    async with await db() as conn:
        cur = await conn.execute("SELECT is_active FROM reward_checks WHERE code=?", (code,))
        row = await cur.fetchone()
        if not row:
            await callback.answer("Чек не найден", show_alert=True)
            return
        new_active = 0 if int(row["is_active"] or 0) else 1
        await conn.execute("UPDATE reward_checks SET is_active=? WHERE code=?", (new_active, code))
        await conn.commit()
    await safe_edit_or_answer(
        callback.message,
        await reward_check_detail_text(code, bot),
        reply_markup=reward_check_detail_kb(code, bool(new_active)),
        parse_mode=ParseMode.HTML,
    )
    await callback.answer("Статус чека изменён")


@admin_router.callback_query(F.data == "admin:create_link")
async def admin_create_link(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.set_state(AdminStates.link)
    await animated_answer(callback.message, f"{ce('link', '🔗')} <b>Новая UTM-ссылка</b>\n\n<i>Отправьте короткий код латиницей.</i>\n\n<blockquote>Например: <code>tiktok_june</code></blockquote>")
    await callback.answer()


@admin_router.message(AdminStates.link)
async def admin_link_save(message: Message, state: FSMContext, bot: Bot) -> None:
    if not await is_admin(message.from_user.id): return
    code = "".join(ch for ch in (message.text or "").strip().lower() if ch.isalnum() or ch in "_-")[:40]
    if not code:
        code = "utm_" + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
    async with await db() as conn:
        await conn.execute("DELETE FROM utm_deleted_links WHERE code=?", (code,))
        await conn.execute("INSERT OR REPLACE INTO utm_links(code,title,created_at) VALUES(?,?,?)", (code, code, now_iso()))
        await conn.commit()
    me = await bot.get_me()
    await state.clear()
    await animated_answer(message, f"{ce('check', '✅')} Ссылка создана:\nhttps://t.me/{me.username}?start={code}")


@admin_router.callback_query(F.data == "admin:withdrawals")
async def admin_withdrawals(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    async with await db() as conn:
        cur = await conn.execute("SELECT w.*, u.username FROM withdraw_requests w LEFT JOIN users u ON u.id=w.user_id WHERE w.status='pending' ORDER BY w.id DESC LIMIT 10")
        rows = await cur.fetchall()
    channel_status = bool_title(await get_setting("payout_channel_enabled", "0"))
    channel_id = await get_setting("payout_channel_chat_id", "")
    if not rows:
        kb = InlineKeyboardMarkup(inline_keyboard=[
            [ibtn("Тест канала выплат", callback_data="wdch:test", icon="send")],
            [ibtn("Настройки", callback_data="cfg:key:payout_channel_chat_id", icon="settings"), ibtn("Админка", callback_data="admin:menu", icon="home")],
        ])
        await safe_edit_or_answer(
            callback.message,
            f"{ce('wallet', '👛')} <b>Заявки на вывод</b>\n\n<i>Сейчас pending-заявок нет.</i>\n\n<b>Канал выплат:</b> {channel_status}\n<code>{html.escape(channel_id or 'не задан')}</code>",
            reply_markup=kb,
            parse_mode=ParseMode.HTML,
        )
    else:
        await safe_edit_or_answer(
            callback.message,
            f"{ce('wallet', '👛')} <b>Заявки на вывод</b>\n\n<b>Канал выплат:</b> {channel_status}\n<code>{html.escape(channel_id or 'не задан')}</code>",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [ibtn("Тест канала выплат", callback_data="wdch:test", icon="send")],
                [ibtn("Настройки канала", callback_data="cfg:key:payout_channel_chat_id", icon="settings")],
            ]),
            parse_mode=ParseMode.HTML,
        )
        for r in rows:
            kb = InlineKeyboardMarkup(inline_keyboard=[[ibtn("Отправить", callback_data=f"wd:ok:{r['id']}", icon="check"), ibtn("Отклонить", callback_data=f"wd:no:{r['id']}", icon="cross")], [ibtn("Профиль", callback_data=f"user:card:{r['user_id']}", icon="profile")]])
            await animated_answer(callback.message, await payout_channel_message_text(r['id']), reply_markup=kb, parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data == "wdch:test")
async def payout_channel_test(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    channel_id = (await get_setting("payout_channel_chat_id", "")).strip()
    if not channel_id:
        await callback.answer("Сначала укажите канал выплат", show_alert=True)
        return
    try:
        msg = await callback.message.bot.send_message(
            resolve_chat_id_value(channel_id),
            f"{ce('check', '✅')} <b>Тест канала выплат</b>\n\n<i>Если вы видите это сообщение — бот может публиковать заявки в этом канале.</i>",
            parse_mode=ParseMode.HTML,
        )
        await callback.answer("Тест отправлен", show_alert=True)
    except Exception as e:
        await callback.answer(f"Ошибка отправки: {str(e)[:160]}", show_alert=True)


@admin_router.callback_query(F.data.startswith("wd:"))
async def admin_withdraw_action(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    _, action, sid = callback.data.split(":")
    ok, status_or_error = await process_withdraw_request(sid, action, callback.from_user.id, callback.message.bot)
    if not ok:
        await callback.answer(status_or_error, show_alert=True)
        return
    await safe_edit_or_answer(callback.message, await payout_channel_message_text(sid), reply_markup=await payout_channel_keyboard(sid, status_or_error), parse_mode=ParseMode.HTML)
    await callback.answer("Готово")


@admin_router.callback_query(F.data.startswith("wdch:"))
async def payout_channel_callback(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id):
        await callback.answer("Эта кнопка доступна только администраторам бота", show_alert=True)
        return
    _, action, sid = callback.data.split(":")
    if action == "profile":
        req = await get_withdraw_request_full(sid)
        if not req:
            await callback.answer("Заявка не найдена", show_alert=True)
            return
        try:
            await callback.message.bot.send_message(
                callback.from_user.id,
                await admin_user_card_text(int(req["user_id"])),
                reply_markup=await admin_user_card_kb(int(req["user_id"])),
                parse_mode=ParseMode.HTML,
            )
            await callback.answer("Профиль отправлен вам в личные сообщения", show_alert=True)
        except Exception:
            balance = fmt_amount(float(req["balance"] or 0))
            username = f"@{req['username']}" if req["username"] else "без username"
            await callback.answer(f"ID: {req['user_id']}\n{username}\nБаланс: {balance}⭐", show_alert=True)
        return
    ok, status_or_error = await process_withdraw_request(sid, action, callback.from_user.id, callback.message.bot)
    if not ok:
        await callback.answer(status_or_error, show_alert=True)
        return
    await update_payout_channel_message(callback.message.bot, sid)
    await callback.answer("Готово", show_alert=False)


@admin_router.callback_query(F.data == "admin:menu")
async def admin_menu_callback(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    await safe_edit_or_answer(callback.message, await admin_dashboard_text(), reply_markup=admin_menu(), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data == "admin:settings")
async def admin_settings(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    await safe_edit_or_answer(callback.message, await settings_home_text(), reply_markup=settings_home_kb())
    await callback.answer()


@admin_router.callback_query(F.data == "admin:api")
async def admin_api(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    await safe_edit_or_answer(callback.message, await settings_category_text("api"), reply_markup=await settings_category_kb("api"))
    await callback.answer()


@admin_router.callback_query(F.data == "admin:diagnostics")
async def admin_diagnostics(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    await safe_edit_or_answer(callback.message, await diagnostics_text(), reply_markup=diagnostics_kb(), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data.startswith("diag:check:"))
async def admin_diagnostics_check(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    target = callback.data.split(":", 2)[2]
    providers = list(DIAGNOSTIC_PROVIDERS) + ["start_ads"] if target == "all" else [target]
    await callback.answer("Проверяю API...")
    results = []
    for provider in providers:
        ok, line = await check_provider_api(provider, callback.from_user, callback.message.chat.id)
        icon = ce("check", "✅") if ok else ce("cross", "❌")
        results.append(f"{icon} {html.escape(line)}")
    await safe_edit_or_answer(
        callback.message,
        await diagnostics_text("Диагностика провайдеров", "\n".join(results)),
        reply_markup=diagnostics_kb(),
        parse_mode=ParseMode.HTML,
    )


@admin_router.callback_query(F.data.startswith("diag:logs:"))
async def admin_provider_logs(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    provider = callback.data.split(":", 2)[2]
    if provider != "all" and provider not in DIAGNOSTIC_PROVIDERS and provider != "start_ads":
        await callback.answer("Провайдер не найден", show_alert=True)
        return
    await safe_edit_or_answer(callback.message, await provider_logs_text(provider), reply_markup=provider_logs_kb(provider), parse_mode=ParseMode.HTML)
    await callback.answer()


@admin_router.callback_query(F.data == "cfg:home")
async def cfg_home(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    await safe_edit_or_answer(callback.message, await settings_home_text(), reply_markup=settings_home_kb())
    await callback.answer()


@admin_router.callback_query(F.data.startswith("cfg:cat:"))
async def cfg_category(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    category = callback.data.split(":", 2)[2]
    if category not in SETTINGS_CATEGORIES:
        await callback.answer("Раздел не найден", show_alert=True)
        return
    await safe_edit_or_answer(callback.message, await settings_category_text(category), reply_markup=await settings_category_kb(category))
    await callback.answer()


@admin_router.callback_query(F.data.startswith("cfg:key:"))
async def cfg_key(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    await state.clear()
    key = callback.data.split(":", 2)[2]
    if key not in SETTINGS_META:
        await callback.answer("Настройка не найдена", show_alert=True)
        return
    await safe_edit_or_answer(callback.message, await setting_card_text(key), reply_markup=await setting_card_kb(key))
    await callback.answer()


@admin_router.callback_query(F.data.startswith("cfg:toggle:"))
async def cfg_toggle(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    key = callback.data.split(":", 2)[2]
    if setting_meta(key).get("kind") != "bool":
        await callback.answer("Это не переключатель", show_alert=True)
        return
    current = await get_setting(key, str(DEFAULT_SETTINGS.get(key, "0")))
    await set_setting(key, "0" if current == "1" else "1")
    await safe_edit_or_answer(callback.message, await setting_card_text(key), reply_markup=await setting_card_kb(key))
    await callback.answer("Сохранено")


@admin_router.callback_query(F.data.startswith("cfg:set:"))
async def cfg_set_enum(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    _, _, key, value = callback.data.split(":", 3)
    ok, normalized, error = normalize_setting_value(key, value)
    if not ok:
        await callback.answer(error, show_alert=True)
        return
    await set_setting(key, normalized)
    await safe_edit_or_answer(callback.message, await setting_card_text(key), reply_markup=await setting_card_kb(key))
    await callback.answer("Сохранено")


@admin_router.callback_query(F.data.startswith("cfg:clear:"))
async def cfg_clear(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    key = callback.data.split(":", 2)[2]
    if key not in SETTINGS_META:
        await callback.answer("Настройка не найдена", show_alert=True)
        return
    await set_setting(key, "")
    await safe_edit_or_answer(callback.message, await setting_card_text(key), reply_markup=await setting_card_kb(key))
    await callback.answer("Очищено")


@admin_router.callback_query(F.data.startswith("cfg:default:"))
async def cfg_default(callback: CallbackQuery) -> None:
    if not await is_admin(callback.from_user.id): return
    key = callback.data.split(":", 2)[2]
    if key not in SETTINGS_META:
        await callback.answer("Настройка не найдена", show_alert=True)
        return
    await set_setting(key, str(DEFAULT_SETTINGS.get(key, "")))
    await safe_edit_or_answer(callback.message, await setting_card_text(key), reply_markup=await setting_card_kb(key))
    await callback.answer("Установлено значение по умолчанию")


@admin_router.callback_query(F.data.startswith("cfg:edit:"))
async def cfg_edit(callback: CallbackQuery, state: FSMContext) -> None:
    if not await is_admin(callback.from_user.id): return
    key = callback.data.split(":", 2)[2]
    if key not in SETTINGS_META:
        await callback.answer("Настройка не найдена", show_alert=True)
        return
    await state.set_state(AdminStates.setting_value)
    await state.update_data(key=key)
    meta = setting_meta(key)
    current = await get_setting(key, str(DEFAULT_SETTINGS.get(key, "")))
    shown = setting_value_for_display(key, current)
    if len(shown) > 1500:
        shown = shown[:1500] + "\n…"

    if is_rich_text_setting(key):
        prompt = (
            f"{ce('edit', '🖋')} <b>{html.escape(meta.get('title', key))}</b>\n\n"
            f"{html.escape(meta.get('desc', ''))}\n\n"
            f"{ce('eye', '👁')} <b>Текущее оформление:</b>\n"
            f"{render_bot_text(current or 'не задано')}\n\n"
            "Отправьте новый текст одним сообщением. Используйте обычное оформление Telegram: "
            "жирный, курсив, подчёркивание, зачёркивание, скрытый текст, цитаты, ссылки и premium emoji. "
            "Бот сам сохранит entities, HTML-теги писать не нужно."
        )
    else:
        prompt = (
            f"{ce('edit', '🖋')} <b>{html.escape(meta.get('title', key))}</b>\n\n"
            f"{html.escape(meta.get('desc', ''))}\n\n"
            f"Текущее значение:\n<code>{html.escape(shown)}</code>\n\n"
            "Отправьте новое значение одним сообщением."
        )
        if meta.get("placeholder"):
            prompt += f"\nПример: <code>{html.escape(str(meta['placeholder']))}</code>"
        if meta.get("options"):
            prompt += "\nВарианты: " + ", ".join(f"<code>{html.escape(str(x))}</code>" for x in meta["options"])
    await animated_answer(callback.message, prompt, reply_markup=cancel_input_kb(key), parse_mode=ParseMode.HTML)
    await callback.answer()



@admin_router.message(AdminStates.setting_value)
async def admin_setting_value(message: Message, state: FSMContext) -> None:
    if not await is_admin(message.from_user.id): return
    data = await state.get_data()
    key = data.get("key")
    if not key or key not in SETTINGS_META:
        await state.clear()
        await animated_answer(message, "Настройка не найдена. Откройте админку заново: /admin")
        return

    if is_rich_text_setting(key):
        normalized = message_rich_html(message)
        if not normalized.strip():
            await animated_answer(message, "⚠️ Отправьте текстовое сообщение.", reply_markup=cancel_input_kb(key))
            return
    else:
        ok, normalized, error = normalize_setting_value(key, message.text or "")
        if not ok:
            await animated_answer(message, "⚠️ " + error, reply_markup=cancel_input_kb(key))
            return

    await set_setting(key, normalized)
    await state.clear()
    await animated_answer(message, f"{ce('check', '✅')} Сохранено. Форматирование и premium emoji сохранены." if is_rich_text_setting(key) else f"{ce('check', '✅')} Сохранено.")
    await animated_answer(message, await setting_card_text(key), reply_markup=await setting_card_kb(key), parse_mode=ParseMode.HTML)






class BanMiddleware(BaseMiddleware):
    async def __call__(self, handler: Callable[[Any, dict[str, Any]], Awaitable[Any]], event: Any, data: dict[str, Any]) -> Any:
        user = getattr(event, "from_user", None)
        if user and not await is_admin(user.id):
            row = await get_user(user.id)
            if row and row["is_banned"]:
                if isinstance(event, CallbackQuery):
                    await event.answer("Доступ к боту ограничен.", show_alert=True)
                elif isinstance(event, Message):
                    await event.answer(f"{ce('lock', '🔒')} Доступ к боту ограничен.")
                return None
        return await handler(event, data)


class FreshOpMiddleware(BaseMiddleware):
    async def __call__(self, handler: Callable[[Any, dict[str, Any]], Awaitable[Any]], event: Any, data: dict[str, Any]) -> Any:
        user = getattr(event, "from_user", None)
        if not user or await is_admin(int(user.id)):
            return await handler(event, data)

        if isinstance(event, Message):
            text = (event.text or "").strip()
            # /start has its own OP flow and referral/deep-link handling.
            if text.startswith("/start"):
                return await handler(event, data)
            await upsert_user(event)
            if not await ensure_fresh_op_for_usage_message(event, user):
                return None

        elif isinstance(event, CallbackQuery):
            callback_data = str(event.data or "")
            # The OP check button itself must stay available even when OP is stale.
            if callback_data == "check_op":
                return await handler(event, data)
            if not await ensure_fresh_op_for_usage_callback(event):
                return None

        return await handler(event, data)


async def main() -> None:
    await init_db()
    runtime_bot_token = (await get_setting("bot_token", BOT_TOKEN)).strip() or BOT_TOKEN
    if not runtime_bot_token:
        raise SystemExit("Укажите BOT_TOKEN в .env или bot_token в настройках БД")
    bot = Bot(runtime_bot_token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    dp = Dispatcher(storage=MemoryStorage())
    router.message.outer_middleware(BanMiddleware())
    router.callback_query.outer_middleware(BanMiddleware())
    router.message.outer_middleware(FreshOpMiddleware())
    router.callback_query.outer_middleware(FreshOpMiddleware())
    dp.include_router(admin_router)
    dp.include_router(router)
    me = await bot.get_me()
    log.info("Bot started: @%s", me.username)
    try:
        await dp.start_polling(bot)
    finally:
        await close_runtime_resources()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Stopped")
