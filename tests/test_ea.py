"""Regresiones locales sin MT5. Ejecutar: python -m unittest discover -s tests -v.

Los contratos revisan el cableado MQL; el harness ejecuta funciones extraídas
SIN reimplementar su lógica, con mocks C++ de las API MT5. No sustituye MetaEditor.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Asistente 3 - TP Fijo.mq5").read_text()


def function(name):
    match = re.search(r"^\w+ " + re.escape(name) + r"\([^\n]*\)\n\{", SOURCE, re.M)
    if not match:
        raise AssertionError(f"Función no encontrada: {name}")
    # Las funciones están a nivel superior; las llaves internas tienen indentación.
    end = SOURCE.index("\n}", match.end()) + 2
    return SOURCE[match.start():end]


class SourceContracts(unittest.TestCase):
    def test_persistence_has_no_stale_local_writer(self):
        self.assertNotIn("GV_HIGH_WATER", function("SaveState"))
        self.assertNotIn("LoadHighWaterBalanceFromFile()", function("LoadState"))
        self.assertEqual(SOURCE.count("GlobalVariableSet(GV_HIGH_WATER,"), 2)
        for name in ("ResetHighWaterBalance", "UpdateHighWaterBalance"):
            body = function(name)
            self.assertLess(body.index("LockHighWater()"), body.index("GlobalVariableSet(GV_HIGH_WATER,"))
            self.assertLess(body.index("SaveHighWaterBalanceToFile("), body.index("UnlockHighWater();"))

    def test_zero_balance_is_persistable(self):
        self.assertIn("if(value<0.0)", function("SaveHighWaterBalanceToFile"))
        self.assertNotIn("if(value<=0.0)", function("SaveHighWaterBalanceToFile"))

    def test_ticket_buttons_use_full_ticket_not_row_index(self):
        body = function("BuildTabPosiciones")
        self.assertIn('StringFormat("%I64u",tr.ticket)', body)
        self.assertIn('PFX_POS+action', body)
        self.assertNotIn('(int)tr.ticket', body)

    def test_manual_closes_not_blocked_by_entry_schedule(self):
        body = function("CloseSymbolTicket") + function("CloseAllSymbolTrades")
        self.assertNotIn("CanOpenNewTrades", body)
        self.assertNotIn("POSITION_MAGIC", body)
        self.assertNotIn("ORDER_MAGIC", body)
        self.assertIn('PositionGetString(POSITION_SYMBOL)!=_Symbol', body)
        self.assertIn('OrderGetString(ORDER_SYMBOL)!=_Symbol', body)

    def test_automatic_scope_unchanged(self):
        self.assertIn('PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber', function("CloseManagedPositions"))
        self.assertIn('OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber', function("CancelManagedPendingOrders"))

    def test_bulk_cancel_precedes_position_snapshot(self):
        body = function("CloseAllSymbolTrades")
        self.assertLess(body.index('CloseSymbolTicket(orders[i],true)'), body.index('i<PositionsTotal()'))
        self.assertIn('CloseSymbolTicket(positions[i],false)', body)
        self.assertIn('lastFailure=g_LastActionMessage', body)

    def test_stop_limits_listed_but_enforcement_not_expanded(self):
        self.assertIn('IsManagedEntryOrderType(otype,true)', function("SyncAllTrades"))
        self.assertIn('ORDER_TYPE_BUY_STOP_LIMIT', function("IsManagedEntryOrderType"))
        self.assertNotIn('IsManagedEntryOrderType', function("EnforceSLTP"))

    def test_split_prevalidation_and_incomplete_feedback(self):
        body = function("SendEntryOrder")
        self.assertLess(body.index('CalcSplitLot(totalLots,parts-1,parts)'), body.index('for(int i=0;'))
        self.assertIn('if(parts<=0) return RejectAction', body)
        self.assertIn('if(result==2)', body)
        self.assertIn('Las partes ejecutadas no se deshacen', body)
        self.assertIn('req.type_filling=pending?ORDER_FILLING_RETURN', body)

    def test_status_survives_tabs_and_is_exported(self):
        self.assertIn('DrawActionStatus();', function("RebuildActiveTab"))
        self.assertIn('JsonEscape(g_LastActionMessage)', function("ExportStateToFile"))
        self.assertIn('g_LastActionMessage', function("DrawActionStatus"))
        self.assertIn('OBJPROP_TOOLTIP,g_LastActionMessage', function("DrawActionStatus"))
        self.assertIn('g_HighWaterBalance-prevHighWater', function("OnTick"))
        self.assertIn('g_HighWaterBalance-previousHighWater', function("OnTimer"))

    def test_mql_delimiters(self):
        # Ignorar comentarios, strings, caracteres y colores MQL antes de contar delimitadores.
        stripped = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', '', SOURCE, flags=re.S)
        stack = []
        for char in stripped:
            if char in '({[':
                stack.append(char)
            elif char in ')}]':
                self.assertTrue(stack)
                self.assertEqual(stack.pop(), {')': '(', '}': '{', ']': '['}[char])
        self.assertEqual(stack, [])


class ExtractedLogic(unittest.TestCase):
    @unittest.skipUnless(shutil.which("g++"), "Requiere g++ para ejecutar el subconjunto compatible")
    def test_actual_mql_functions_with_terminal_mocks(self):
        names = ["LockHighWater", "UnlockHighWater", "UpdateHighWaterBalance", "ResetHighWaterBalance",
                 "CalcLotFromRisk", "VolumeDigits", "CalcSplitCount", "CalcSplitLot", "TradeRetcodeReason",
                 "CanSendTradeRequest", "SendCheckedRequest", "CloseSymbolTicket"]
        extracted = '\n\n'.join(function(name) for name in names)
        harness = (ROOT / 'tests' / 'terminal_harness.cpp').read_text()
        constants = sorted(set(re.findall(r'\b(?:ACCOUNT|TERMINAL|MQL|SYMBOL|ORDER|POSITION|TRADE)_[A-Z_]+\b', extracted + harness)))
        enum = 'enum { ' + ', '.join(constants) + ' };\n'
        program = harness.replace('// CONSTANTS_FROM_MQL', enum).replace('// FUNCTIONS_FROM_MQL', extracted)
        with tempfile.TemporaryDirectory() as directory:
            cpp = Path(directory) / 'test.cpp'
            exe = Path(directory) / 'test'
            cpp.write_text(program)
            result = subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', str(cpp), '-o', str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('regresiones OK', result.stdout)


if __name__ == '__main__':
    unittest.main()
