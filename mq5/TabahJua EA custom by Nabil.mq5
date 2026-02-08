//+------------------------------------------------------------------+
//|                                        SapuanNonan_XAUUSD_Pro.mq5 |
//|                                    Copyright 2025, Sapuan Nonan   |
//|                                      https://t.me/sapuannonan     |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2025, Sapuan Nonan"
#property link        "https://t.me/sapuannonan"
#property version     "2.00"
#property description "Advanced Dynamic Grid EA for XAUUSD with 20% DD Protection"
#property description "Features: Auto Scaling, News Filter, Weekend Protection, LDR 2026"
#property description "Optimized for Vantage Cent Account - Spread 32-35 pips"

#include <Trade\PositionInfo.mqh>
#include <Trade\Trade.mqh>

CPositionInfo m_position;
CTrade trade;

enum ENUM_ST
{
   Awerage   = 0,
   PartClose = 1
};

enum ENUM_LOT_MODE
{
   FIXED_LOT = 0,
   PERCENT_RISK = 1,
   BALANCE_MULTIPLIER = 2,
   EQUITY_BASED = 3
};

enum ENUM_GRID_MODE
{
   FIXED_GRID = 0,
   ATR_BASED = 1,
   VOLATILITY_ADAPTIVE = 2
};

input group "======== RISK MANAGEMENT ========"
input double iMaxDrawdownPercent = 20.0;
input double iWarningDrawdownPercent = 15.0;
input double iSafeDrawdownPercent = 10.0;

input double iSuspendDDPercent = 18.0;
input double iEmergencyCloseDDPercent = 19.0;

input group "======== CAPITAL PROTECTION ========"
input bool iUseCapitalProtection = true;
input double iMinEquityPercentOfStart = 80.0; // preserve at least this % of EA-start balance
input bool iUsePeakEquityLock = false;
input double iMinEquityPercentOfPeak = 70.0;  // if enabled, preserves % of peak equity since EA start
input bool iCloseAllOnProtection = true;
input bool iHaltTradingAfterProtection = true;

input group "======== MARGIN PROTECTION ========"
input bool iUseMarginProtection = true;
input double iMinMarginLevelForNewTrades = 400.0;
input double iEmergencyMinMarginLevel = 200.0;

input group "======== LOT MANAGEMENT ========"
input ENUM_LOT_MODE iLotMode = EQUITY_BASED;
input double iRiskPercent = 0.8;
input double iMinLot = 0.05;
input double iMaxLot = 2.56;
input double iMartingaleMultiplier = 1.6;

input group "======== GRID SETTINGS ========"
input ENUM_GRID_MODE iGridMode = VOLATILITY_ADAPTIVE;
input int iBaseGridStep = 150;
input double iATRMultiplier = 1.5;
input int iATRPeriod = 14;
input double iMinGridStep = 80;
input double iMaxGridStep = 300;
input int iAbsoluteMaxGrids = 5;

input group "======== TAKE PROFIT ========"
input int iTakeProfit = 80;
input int iMinimalProfit = 40;
input ENUM_ST iCloseOrder = Awerage;

input group "======== FILTERS ========"
input int iMaxSpread = 40;
input int iStartHour = 7;
input int iEndHour = 21;

input group "======== WEEKEND & NEWS ========"
input bool iAutoCloseOnFriday = true;
input int iFridayCloseHour = 21;
input bool iAvoidMondayGap = true;
input int iMondayStartHour = 3;
input bool iAvoidMajorNews = true;
input int iNewsBufferMinutes = 30;

input group "======== DAILY LIMITS ========"
input bool iUseDailyTarget = true;
input double iDailyProfitTarget = 100;
input double iDailyLossLimit = 50;
input bool iDailyLimitsUseEquity = true;

input group "======== SYSTEM ========"
input int iMagicNumber = 20250129;
input int iSlippage = 30;
input bool iShowDashboard = true;

bool g_EmergencyMode = false;
datetime g_EmergencyStartTime = 0;
int g_EmergencyCooldownMinutes = 60;
datetime g_LastResetDate = 0;
double g_DailyStartBalance = 0;
double g_DailyStartEquity = 0;
bool g_DailyTargetReached = false;
bool g_DailyLossLimitReached = false;

double g_EAStartBalance = 0;
double g_EAStartEquity = 0;
double g_PeakBalance = 0;
double g_PeakEquity = 0;

bool g_TradingHalted = false;
string g_TradingHaltReason = "";

int g_ATRHandle = INVALID_HANDLE;

bool EnsureAtrHandle()
{
   if(g_ATRHandle != INVALID_HANDLE)
      return true;
   g_ATRHandle = iATR(Symbol(), PERIOD_H1, iATRPeriod);
   return (g_ATRHandle != INVALID_HANDLE);
}

void ReleaseAtrHandle()
{
   if(g_ATRHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_ATRHandle);
      g_ATRHandle = INVALID_HANDLE;
   }
}

bool IsTradeEnvironmentOK(string &reason)
{
   reason = "";
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      reason = "Terminal not connected";
      return false;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      reason = "Terminal trading disabled";
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      reason = "Algo trading disabled for EA";
      return false;
   }
   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0)
   {
      reason = "Account trading not allowed";
      return false;
   }
   long trade_mode = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      reason = "Symbol trade mode disabled";
      return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
   {
      reason = "No valid tick (market closed?)";
      return false;
   }
   return true;
}

void LogTradeFailure(const string side, const double lot, const double price, const double grid_step)
{
   int err = GetLastError();
   PrintFormat("%s FAILED | lot=%.2f price=%.5f grid=%.1f | retcode=%d (%s) | lastError=%d",
               side, lot, price, grid_step,
               (int)trade.ResultRetcode(), trade.ResultRetcodeDescription(), err);
}

struct NewsEvent
{
   int day_of_week;
   int hour;
   int minute;
   string description;
};

NewsEvent g_MajorNews[] = 
{
   {5, 13, 30, "NFP"},
   {3, 18, 0, "FOMC"},
   {0, 13, 30, "US CPI"},
   {4, 12, 45, "ECB"},
   {4, 12, 0, "BOE"}
};

struct LDREvent
{
   int month;
   int day;
   string description;
};

LDREvent g_LDR2026[] = 
{
   {1,7,"LDR"},{1,16,"LDR"},{1,27,"LDR"},
   {2,3,"LDR"},{2,12,"LDR"},{2,21,"LDR"},
   {3,3,"LDR"},{3,11,"LDR"},{3,20,"LDR"},{3,31,"LDR"},
   {4,7,"LDR"},{4,16,"LDR"},{4,25,"LDR"},
   {5,5,"LDR"},{5,13,"LDR"},{5,22,"LDR"},
   {6,2,"LDR"},{6,9,"LDR"},{6,18,"LDR"},{6,27,"LDR"},
   {7,7,"LDR"},{7,15,"LDR"},{7,24,"LDR"},
   {8,4,"LDR"},{8,11,"LDR"},{8,20,"LDR"},{8,29,"LDR"},
   {9,8,"LDR"},{9,16,"LDR"},{9,25,"LDR"},
   {10,6,"LDR"},{10,13,"LDR"},{10,22,"LDR"},{10,31,"LDR"},
   {11,10,"LDR"},{11,18,"LDR"},{11,27,"LDR"},
   {12,8,"LDR"},{12,15,"LDR"},{12,24,"LDR"}
};

struct DrawdownProjection
{
   double current_dd;
   double projected_dd;
   double worst_case_dd;
   bool safe_to_trade;
   string warning_message;
   int max_safe_grids;
};

int OnInit()
{
   Comment("");
   trade.LogLevel(LOG_LEVEL_ERRORS);
   trade.SetExpertMagicNumber(iMagicNumber);
   trade.SetDeviationInPoints(iSlippage);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(Symbol());

   // Pre-create indicator handle (faster + fewer handle leaks on some terminals)
   EnsureAtrHandle();

   g_EAStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_EAStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_PeakBalance = g_EAStartBalance;
   g_PeakEquity = g_EAStartEquity;

   g_DailyStartBalance = g_EAStartBalance;
   g_DailyStartEquity = g_EAStartEquity;
   g_LastResetDate = iTime(Symbol(), PERIOD_D1, 0);
   Print("=======================================");
   Print("  SapuanNonan XAUUSD Pro EA v2.0");
   Print("  Copyright 2025, Sapuan Nonan");
   Print("=======================================");
   Print("Balance: $", AccountInfoDouble(ACCOUNT_BALANCE));
   Print("Max DD: ", iMaxDrawdownPercent, "%");
   Print("=======================================");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
   ReleaseAtrHandle();
   Print("EA Stopped - Balance: $", AccountInfoDouble(ACCOUNT_BALANCE));
}

void OnTick()
{
   UpdateAccountPeaks();
   if(iUseCapitalProtection)
      CheckCapitalProtection();
   if(g_TradingHalted)
   {
      if(iShowDashboard)
         ShowCompleteDashboard();
      return;
   }

   CheckEmergencyShutdown();
   if(g_EmergencyMode && !CanExitEmergencyMode())
      return;
   if(IsFridayCloseTime())
   {
      HandleFridayClose();
      return;
   }
   if(IsMondayGapPeriod())
   {
      Comment("MONDAY GAP PROTECTION\nWaiting for market stabilization...");
      return;
   }
   if(!CheckDailyLimits())
      return;
   double current_dd = GetCurrentDrawdown();
   if(current_dd >= iSuspendDDPercent)
   {
      Comment(StringFormat("DD TOO HIGH: %.2f%%\nTrading suspended", current_dd));
      return;
   }
   if(!AllFiltersPass())
      return;
   ExecuteTradingLogic();
   ManageExistingPositions();
   if(iShowDashboard)
      ShowCompleteDashboard();
}

void UpdateAccountPeaks()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance > g_PeakBalance)
      g_PeakBalance = balance;
   if(equity > g_PeakEquity)
      g_PeakEquity = equity;
}

bool CloseAllManagedPositions(const string reason)
{
   bool ok = true;
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == Symbol() && m_position.Magic() == iMagicNumber)
         {
            ulong ticket = m_position.Ticket();
            ResetLastError();
            if(trade.PositionClose(ticket))
               closed++;
            else
            {
               ok = false;
               PrintFormat("CLOSE FAILED | ticket=%I64u | reason=%s | retcode=%d (%s) | lastError=%d",
                           ticket, reason,
                           (int)trade.ResultRetcode(), trade.ResultRetcodeDescription(), GetLastError());
            }
         }
      }
   }
   if(closed > 0)
      PrintFormat("Closed %d positions (%s)", closed, reason);
   return ok;
}

void HaltTrading(const string reason, const bool close_positions)
{
   if(g_TradingHalted)
      return;
   g_TradingHalted = true;
   g_TradingHaltReason = reason;
   Print("TRADING HALTED: ", reason);
   if(close_positions)
      CloseAllManagedPositions(reason);
}

void CheckCapitalProtection()
{
   if(!iUseCapitalProtection)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double used_margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double margin_level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(used_margin <= 0.0 || margin_level <= 0.0)
      margin_level = 1000000.0;

   double floor_start = 0.0;
   if(g_EAStartBalance > 0.0)
      floor_start = g_EAStartBalance * (iMinEquityPercentOfStart / 100.0);

   double floor_peak = 0.0;
   if(iUsePeakEquityLock && g_PeakEquity > 0.0)
      floor_peak = g_PeakEquity * (iMinEquityPercentOfPeak / 100.0);

   if(floor_start > 0.0 && equity <= floor_start)
   {
      string reason = StringFormat("Capital protection: equity %.2f <= start-floor %.2f (%.1f%% of start)",
                                  equity, floor_start, iMinEquityPercentOfStart);
      if(iHaltTradingAfterProtection)
         HaltTrading(reason, iCloseAllOnProtection);
      else if(iCloseAllOnProtection)
         CloseAllManagedPositions(reason);
      return;
   }

   if(floor_peak > 0.0 && equity <= floor_peak)
   {
      string reason = StringFormat("Peak lock: equity %.2f <= peak-floor %.2f (%.1f%% of peak)",
                                  equity, floor_peak, iMinEquityPercentOfPeak);
      if(iHaltTradingAfterProtection)
         HaltTrading(reason, iCloseAllOnProtection);
      else if(iCloseAllOnProtection)
         CloseAllManagedPositions(reason);
      return;
   }

   if(iUseMarginProtection && margin_level <= iEmergencyMinMarginLevel)
   {
      string reason = StringFormat("Margin emergency: margin level %.1f%% <= %.1f%%", margin_level, iEmergencyMinMarginLevel);
      if(iHaltTradingAfterProtection)
         HaltTrading(reason, true);
      else
         CloseAllManagedPositions(reason);
      return;
   }
}

double GetPipValue()
{
   // "Pip" here means the common pip-size used by most symbols:
   // - 5/3-digit quotes: 1 pip = 10 points
   // - otherwise: 1 pip = 1 point
   const double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   const int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
}

double GetCurrentDrawdown()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0)
      return 0;
   return ((balance - equity) / balance) * 100.0;
}

int CountBuyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == Symbol() && 
            m_position.Magic() == iMagicNumber &&
            m_position.PositionType() == POSITION_TYPE_BUY)
            count++;
      }
   }
   return count;
}

int CountSellPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == Symbol() && 
            m_position.Magic() == iMagicNumber &&
            m_position.PositionType() == POSITION_TYPE_SELL)
            count++;
      }
   }
   return count;
}

double GetLastBuyPrice()
{
   double last_price = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == Symbol() && 
            m_position.Magic() == iMagicNumber &&
            m_position.PositionType() == POSITION_TYPE_BUY)
         {
            double price = m_position.PriceOpen();
            if(last_price == 0 || price < last_price)
               last_price = price;
         }
      }
   }
   return last_price;
}

double GetLastSellPrice()
{
   double last_price = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == Symbol() && 
            m_position.Magic() == iMagicNumber &&
            m_position.PositionType() == POSITION_TYPE_SELL)
         {
            double price = m_position.PriceOpen();
            if(last_price == 0 || price > last_price)
               last_price = price;
         }
      }
   }
   return last_price;
}

double GetCurrentATR()
{
   if(!EnsureAtrHandle())
      return 0;
   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   if(CopyBuffer(g_ATRHandle, 0, 0, 1, atr_buffer) <= 0)
      return 0;
   double atr_pips = atr_buffer[0] / GetPipValue();
   return atr_pips;
}

double GetAverageATR(int periods = 20)
{
   if(!EnsureAtrHandle())
      return 0;
   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   if(CopyBuffer(g_ATRHandle, 0, 0, periods, atr_buffer) <= 0)
      return 0;
   double sum = 0;
   for(int i = 0; i < periods; i++)
      sum += atr_buffer[i];
   double avg_atr = (sum / periods) / GetPipValue();
   return avg_atr;
}

bool IsHighVolatilityExpansion()
{
   double current_atr = GetCurrentATR();
   double average_atr = GetAverageATR(20);
   if(average_atr == 0)
      return false;
   return ((current_atr / average_atr) >= 1.5);
}

double CalculateDynamicGridStep(int current_grid_level)
{
   double grid_step = iBaseGridStep;
   if(iGridMode == VOLATILITY_ADAPTIVE)
   {
      double atr = GetCurrentATR();
      double avg_atr = GetAverageATR(20);
      if(atr > 0 && avg_atr > 0)
      {
         grid_step = atr * iATRMultiplier;
         double volatility_ratio = atr / avg_atr;
         if(volatility_ratio > 1.5)
            grid_step = grid_step * 1.5;
         else if(volatility_ratio < 0.7)
            grid_step = grid_step * 0.8;
         double level_multiplier = 1.0 + (current_grid_level * 0.1);
         grid_step = grid_step * level_multiplier;
      }
      double current_dd = GetCurrentDrawdown();
      if(current_dd >= 15.0)
         grid_step = grid_step * 2.0;
      else if(current_dd >= 10.0)
         grid_step = grid_step * 1.5;
      else if(current_dd >= 5.0)
         grid_step = grid_step * 1.2;
   }
   if(grid_step < iMinGridStep)
      grid_step = iMinGridStep;
   if(grid_step > iMaxGridStep)
      grid_step = iMaxGridStep;
   return NormalizeDouble(grid_step, 1);
}

double NormalizeLot(double lot)
{
   double lot_step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double min_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / lot_step) * lot_step;
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;
   return NormalizeDouble(lot, 2);
}

double CalculateBaseLotSize()
{
   double account_size = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = account_size * (iRiskPercent / 100.0);

   // Approximate money value per pip per 1.0 lot using tick value.
   // Fallback to 1.0 if broker doesn't provide values.
   double value_per_pip_per_lot = 1.0;
   double tick_value = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double pip_size = GetPipValue();
   if(tick_value > 0.0 && tick_size > 0.0 && pip_size > 0.0)
      value_per_pip_per_lot = tick_value * (pip_size / tick_size);
   if(value_per_pip_per_lot <= 0.0)
      value_per_pip_per_lot = 1.0;

   double stop_distance_pips = iBaseGridStep;
   double lot = risk_amount / (stop_distance_pips * value_per_pip_per_lot);
   lot = NormalizeLot(lot);
   if(lot < iMinLot) lot = iMinLot;
   if(lot > iMaxLot) lot = iMaxLot;
   return lot;
}

double CalculateDDSafeLotSize(int grid_level)
{
   double current_dd = GetCurrentDrawdown();
   double base_lot = CalculateBaseLotSize();
   double lot = base_lot;
   for(int i = 0; i < grid_level; i++)
      lot = lot * iMartingaleMultiplier;
   double dd_factor = 1.0;
   if(current_dd >= 15.0)
      dd_factor = 0.3;
   else if(current_dd >= 10.0)
      dd_factor = 0.5;
   else if(current_dd >= 5.0)
      dd_factor = 0.7;
   lot = lot * dd_factor;
   if(IsHighVolatilityExpansion())
      lot = lot * 0.7;
   lot = NormalizeLot(lot);
   if(lot > iMaxLot)
      lot = iMaxLot;
   double grid_step = CalculateDynamicGridStep(grid_level);
   DrawdownProjection proj = CalculateDrawdownProjection(lot, grid_step);
   int safety_iterations = 0;
   while(!proj.safe_to_trade && lot > SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN) && safety_iterations < 10)
   {
      lot = lot * 0.8;
      proj = CalculateDrawdownProjection(lot, grid_step);
      safety_iterations++;
   }
   if(!proj.safe_to_trade)
      return 0;
   return lot;
}

DrawdownProjection CalculateDrawdownProjection(double new_lot, double new_grid_step)
{
   DrawdownProjection proj;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   proj.current_dd = ((balance - equity) / balance) * 100.0;
   double floating_loss = balance - equity;
   double new_position_risk = new_lot * new_grid_step * 1.0;
   double projected_total_loss = floating_loss + new_position_risk;
   proj.projected_dd = (projected_total_loss / balance) * 100.0;
   double worst_case_loss = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == Symbol() && m_position.Magic() == iMagicNumber)
         {
            double position_lot = m_position.Volume();
            worst_case_loss += position_lot * new_grid_step * 1.0;
         }
      }
   }
   worst_case_loss += new_lot * new_grid_step * 1.0;
   proj.worst_case_dd = (worst_case_loss / balance) * 100.0;
   proj.safe_to_trade = true;
   proj.max_safe_grids = iAbsoluteMaxGrids;
   proj.warning_message = "";
   if(proj.current_dd >= iMaxDrawdownPercent)
   {
      proj.safe_to_trade = false;
      proj.max_safe_grids = 0;
      proj.warning_message = "CRITICAL: Max DD reached!";
      return proj;
   }
   if(proj.projected_dd >= iMaxDrawdownPercent)
   {
      proj.safe_to_trade = false;
      proj.warning_message = "Projected DD exceeds limit!";
      return proj;
   }
   if(proj.worst_case_dd >= iMaxDrawdownPercent)
   {
      proj.safe_to_trade = false;
      proj.warning_message = "Worst case DD exceeds limit!";
      return proj;
   }
   if(proj.current_dd >= iWarningDrawdownPercent)
   {
      proj.max_safe_grids = 2;
      proj.warning_message = "WARNING: DD > 15%";
   }
   else if(proj.current_dd >= iSafeDrawdownPercent)
   {
      proj.max_safe_grids = 3;
      proj.warning_message = "CAUTION: DD > 10%";
   }
   return proj;
}

int CalculateDDSafeMaxGrids()
{
   double current_dd = GetCurrentDrawdown();
   int max_grids = iAbsoluteMaxGrids;
   if(current_dd >= iSuspendDDPercent)
      max_grids = 0;
   else if(current_dd >= 15.0)
      max_grids = 1;
   else if(current_dd >= 12.0)
      max_grids = 2;
   else if(current_dd >= 10.0)
      max_grids = 3;
   else if(current_dd >= 5.0)
      max_grids = 4;
   // IMPORTANT: when there are no open positions, used margin is often 0,
   // and ACCOUNT_MARGIN_LEVEL may return 0. That would incorrectly block
   // the very first trade. Only enforce margin-level limits when margin is used.
   double used_margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double margin_level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(used_margin <= 0.0 || margin_level <= 0.0)
      margin_level = 1000000.0;
   if(iUseMarginProtection && margin_level < iEmergencyMinMarginLevel)
      max_grids = 0;
   else if(iUseMarginProtection && margin_level < iMinMarginLevelForNewTrades)
      max_grids = MathMin(max_grids, 2);
   if(IsHighVolatilityExpansion())
      max_grids = MathMin(max_grids, 2);
   return max_grids;
}

void CheckEmergencyShutdown()
{
   double current_dd = GetCurrentDrawdown();
   if(current_dd >= iEmergencyCloseDDPercent && !g_EmergencyMode)
   {
      Print("EMERGENCY! DD: ", current_dd, "%");
      CloseAllManagedPositions("Emergency DD close");
      g_EmergencyMode = true;
      g_EmergencyStartTime = TimeCurrent();
   }
}

bool CanExitEmergencyMode()
{
   if(!g_EmergencyMode)
      return true;
   int minutes_passed = (int)((TimeCurrent() - g_EmergencyStartTime) / 60);
   if(minutes_passed < g_EmergencyCooldownMinutes)
   {
      Comment(StringFormat("EMERGENCY COOLDOWN\n%d min remaining", g_EmergencyCooldownMinutes - minutes_passed));
      return false;
   }
   double current_dd = GetCurrentDrawdown();
   if(current_dd < 5.0)
   {
      g_EmergencyMode = false;
      Print("Emergency mode OFF");
      return true;
   }
   return false;
}

bool IsFridayCloseTime()
{
   if(!iAutoCloseOnFriday)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   return (dt.day_of_week == 5 && dt.hour >= iFridayCloseHour);
}

void HandleFridayClose()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == Symbol() && m_position.Magic() == iMagicNumber)
            count++;
      }
   }
   if(count > 0)
   {
      Comment("FRIDAY CLOSE\nClosing positions...");
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(m_position.SelectByIndex(i))
         {
            if(m_position.Symbol() == Symbol() && m_position.Magic() == iMagicNumber)
               trade.PositionClose(m_position.Ticket());
         }
      }
   }
}

bool IsMondayGapPeriod()
{
   if(!iAvoidMondayGap)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   return (dt.day_of_week == 1 && dt.hour < iMondayStartHour);
}

bool IsNewsTime()
{
   if(!iAvoidMajorNews)
      return false;
   MqlDateTime dt;
   // News schedule in this EA is defined in GMT.
   TimeToStruct(TimeGMT(), dt);
   datetime current_time = TimeGMT();
   for(int i = 0; i < ArraySize(g_MajorNews); i++)
   {
      NewsEvent news = g_MajorNews[i];
      if(news.day_of_week != 0 && news.day_of_week != dt.day_of_week)
         continue;
      MqlDateTime news_dt = dt;
      news_dt.hour = news.hour;
      news_dt.min = news.minute;
      news_dt.sec = 0;
      datetime news_time = StructToTime(news_dt);
      datetime buffer_before = news_time - (iNewsBufferMinutes * 60);
      datetime buffer_after = news_time + (iNewsBufferMinutes * 60);
      if(current_time >= buffer_before && current_time <= buffer_after)
      {
         Comment(StringFormat("NEWS: %s\nTrading paused", news.description));
         return true;
      }
   }
   return false;
}

bool IsLDRDate()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   for(int i = 0; i < ArraySize(g_LDR2026); i++)
   {
      if(g_LDR2026[i].month == dt.mon && g_LDR2026[i].day == dt.day)
         return true;
   }
   return false;
}

void ResetDailyCounters()
{
   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   if(today != g_LastResetDate)
   {
      g_LastResetDate = today;
      g_DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_DailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_DailyTargetReached = false;
      g_DailyLossLimitReached = false;
   }
}

bool CheckDailyLimits()
{
   if(!iUseDailyTarget)
      return true;
   ResetDailyCounters();
   double daily_pl = 0.0;
   if(iDailyLimitsUseEquity)
      daily_pl = AccountInfoDouble(ACCOUNT_EQUITY) - g_DailyStartEquity;
   else
      daily_pl = AccountInfoDouble(ACCOUNT_BALANCE) - g_DailyStartBalance;
   if(daily_pl >= iDailyProfitTarget && !g_DailyTargetReached)
   {
      g_DailyTargetReached = true;
      CloseAllManagedPositions("Daily profit target");
      Comment(StringFormat("TARGET REACHED!\nProfit: $%.2f", daily_pl));
      return false;
   }
   if(daily_pl <= -iDailyLossLimit && !g_DailyLossLimitReached)
   {
      g_DailyLossLimitReached = true;
      CloseAllManagedPositions("Daily loss limit");
      Comment(StringFormat("LOSS LIMIT!\nLoss: $%.2f", daily_pl));
      return false;
   }
   return true;
}

bool IsSpreadAcceptable()
{
   long spread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   return (spread <= iMaxSpread);
}

bool IsTimeToTrade()
{
   MqlDateTime dt;
   // Use broker server time for session filter.
   TimeToStruct(TimeTradeServer(), dt);
   return (dt.hour >= iStartHour && dt.hour < iEndHour);
}

bool AllFiltersPass()
{
   static datetime last_env_log = 0;
   string reason;
   if(!IsTradeEnvironmentOK(reason))
   {
      datetime now = TimeCurrent();
      if(now - last_env_log >= 60)
      {
         Print("Trading disabled: ", reason);
         last_env_log = now;
      }
      return false;
   }
   if(!IsTimeToTrade())
      return false;
   if(!IsSpreadAcceptable())
      return false;
   if(IsNewsTime())
      return false;
   return true;
}

bool ShouldOpenBuy(double grid_step)
{
   int buy_count = CountBuyPositions();
   if(buy_count == 0)
      return true;
   double last_buy = GetLastBuyPrice();
   if(last_buy == 0)
      return true;
   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick))
      return false;
   double distance = (last_buy - tick.ask) / GetPipValue();
   return (distance >= grid_step);
}

bool ShouldOpenSell(double grid_step)
{
   int sell_count = CountSellPositions();
   if(sell_count == 0)
      return true;
   double last_sell = GetLastSellPrice();
   if(last_sell == 0)
      return true;
   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick))
      return false;
   double distance = (tick.bid - last_sell) / GetPipValue();
   return (distance >= grid_step);
}

void ExecuteTradingLogic()
{
   int buy_count = CountBuyPositions();
   int sell_count = CountSellPositions();
   int max_safe_grids = CalculateDDSafeMaxGrids();
   if(max_safe_grids == 0)
   {
      static datetime last_block_log = 0;
      datetime now = TimeCurrent();
      if(now - last_block_log >= 60)
      {
         double used_margin = AccountInfoDouble(ACCOUNT_MARGIN);
         double margin_level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
         PrintFormat("Trading blocked (max_safe_grids=0) | DD=%.2f%% | Margin=%.2f | MarginLevel=%.2f | Spread(points)=%d",
                     GetCurrentDrawdown(), used_margin, margin_level, (int)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD));
         last_block_log = now;
      }
      return;
   }
   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick))
      return;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(Symbol(), PERIOD_CURRENT, 0, 2, rates) < 2)
      return;
   bool is_ldr = IsLDRDate();
   if(is_ldr)
      max_safe_grids = MathMin(max_safe_grids, 2);
   if(buy_count < max_safe_grids)
   {
      double buy_grid = CalculateDynamicGridStep(buy_count);
      double buy_lot = CalculateDDSafeLotSize(buy_count);
      if(buy_lot > 0)
      {
         DrawdownProjection proj = CalculateDrawdownProjection(buy_lot, buy_grid);
         if(proj.safe_to_trade)
         {
            if(rates[1].close > rates[1].open)
            {
               if(ShouldOpenBuy(buy_grid))
               {
                  ResetLastError();
                  if(trade.Buy(buy_lot, Symbol(), tick.ask, 0, 0, "SN_Buy"))
                  {
                     Print("BUY | Lot: ", buy_lot, " | Grid: ", buy_grid);
                  }
                  else
                  {
                     LogTradeFailure("BUY", buy_lot, tick.ask, buy_grid);
                  }
               }
            }
         }
      }
   }
   if(sell_count < max_safe_grids)
   {
      double sell_grid = CalculateDynamicGridStep(sell_count);
      double sell_lot = CalculateDDSafeLotSize(sell_count);
      if(sell_lot > 0)
      {
         DrawdownProjection proj = CalculateDrawdownProjection(sell_lot, sell_grid);
         if(proj.safe_to_trade)
         {
            if(rates[1].close < rates[1].open)
            {
               if(ShouldOpenSell(sell_grid))
               {
                  ResetLastError();
                  if(trade.Sell(sell_lot, Symbol(), tick.bid, 0, 0, "SN_Sell"))
                  {
                     Print("SELL | Lot: ", sell_lot, " | Grid: ", sell_grid);
                  }
                  else
                  {
                     LogTradeFailure("SELL", sell_lot, tick.bid, sell_grid);
                  }
               }
            }
         }
      }
   }
}

void ManageExistingPositions()
{
   int buy_count = CountBuyPositions();
   int sell_count = CountSellPositions();
   MqlTick tick;
   if(!SymbolInfoTick(Symbol(), tick))
      return;
   if(iCloseOrder == Awerage)
   {
      if(buy_count >= 2)
      {
         double buy_max = 0, buy_min = 0, lot_max = 0, lot_min = 0;
         ulong tick_max = 0, tick_min = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_position.SelectByIndex(i))
            {
               if(m_position.Symbol() == Symbol() && 
                  m_position.Magic() == iMagicNumber &&
                  m_position.PositionType() == POSITION_TYPE_BUY)
               {
                  double op = m_position.PriceOpen();
                  double lt = m_position.Volume();
                  ulong tk = m_position.Ticket();
                  if(op > buy_max || buy_max == 0)
                  {
                     buy_max = op;
                     lot_max = lt;
                     tick_max = tk;
                  }
                  if(op < buy_min || buy_min == 0)
                  {
                     buy_min = op;
                     lot_min = lt;
                     tick_min = tk;
                  }
               }
            }
         }
         if(buy_max > 0 && buy_min > 0)
         {
            double avg_price = (buy_max * lot_max + buy_min * lot_min) / 
                              (lot_max + lot_min) + 
                              iMinimalProfit * GetPipValue();
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               if(m_position.SelectByIndex(i))
               {
                  if(m_position.Symbol() == Symbol() && m_position.Magic() == iMagicNumber)
                  {
                     ulong tk = m_position.Ticket();
                     double tp = m_position.TakeProfit();
                     if(tk == tick_max || tk == tick_min)
                     {
                        if(tick.bid < avg_price && tp != avg_price)
                           trade.PositionModify(tk, m_position.StopLoss(), avg_price);
                     }
                     else if(tp != 0)
                     {
                        trade.PositionModify(tk, 0, 0);
                     }
                  }
               }
            }
         }
      }
      if(sell_count >= 2)
      {
         double sell_max = 0, sell_min = 0, lot_max = 0, lot_min = 0;
         ulong tick_max = 0, tick_min = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_position.SelectByIndex(i))
            {
               if(m_position.Symbol() == Symbol() && 
                  m_position.Magic() == iMagicNumber &&
                  m_position.PositionType() == POSITION_TYPE_SELL)
               {
                  double op = m_position.PriceOpen();
                  double lt = m_position.Volume();
                  ulong tk = m_position.Ticket();
                  if(op > sell_max || sell_max == 0)
                  {
                     sell_max = op;
                     lot_max = lt;
                     tick_max = tk;
                  }
                  if(op < sell_min || sell_min == 0)
                  {
                     sell_min = op;
                     lot_min = lt;
                     tick_min = tk;
                  }
               }
            }
         }
         if(sell_max > 0 && sell_min > 0)
         {
            double avg_price = (sell_max * lot_max + sell_min * lot_min) / 
                              (lot_max + lot_min) - 
                              iMinimalProfit * GetPipValue();
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               if(m_position.SelectByIndex(i))
               {
                  if(m_position.Symbol() == Symbol() && m_position.Magic() == iMagicNumber)
                  {
                     ulong tk = m_position.Ticket();
                     double tp = m_position.TakeProfit();
                     if(tk == tick_max || tk == tick_min)
                     {
                        if(tick.ask > avg_price && tp != avg_price)
                           trade.PositionModify(tk, m_position.StopLoss(), avg_price);
                     }
                     else if(tp != 0)
                     {
                        trade.PositionModify(tk, 0, 0);
                     }
                  }
               }
            }
         }
      }
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == Symbol() && m_position.Magic() == iMagicNumber)
         {
            double tp = m_position.TakeProfit();
            if(m_position.PositionType() == POSITION_TYPE_BUY && buy_count == 1 && tp == 0)
            {
               double new_tp = tick.ask + iTakeProfit * GetPipValue();
               trade.PositionModify(m_position.Ticket(), 0, new_tp);
            }
            if(m_position.PositionType() == POSITION_TYPE_SELL && sell_count == 1 && tp == 0)
            {
               double new_tp = tick.bid - iTakeProfit * GetPipValue();
               trade.PositionModify(m_position.Ticket(), 0, new_tp);
            }
         }
      }
   }
}

string CreateDDBar(double dd)
{
   string bar = "[";
   int filled = (int)((dd / iMaxDrawdownPercent) * 20);
   for(int i = 0; i < 20; i++)
   {
      if(i < filled)
      {
         if(dd < 5.0)
            bar += "#";
         else if(dd < 10.0)
            bar += "#";
         else if(dd < 15.0)
            bar += "#";
         else
            bar += "#";
      }
      else
         bar += ".";
   }
   bar += "] " + DoubleToString(dd, 1) + "%";
   return bar;
}

void ShowCompleteDashboard()
{
   string info = "";
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = GetCurrentDrawdown();
   double floating = equity - balance;
   double margin = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   int buy = CountBuyPositions();
   int sell = CountSellPositions();
   int max = CalculateDDSafeMaxGrids();
   double atr = GetCurrentATR();
   long spread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   string dd_status = "";
   if(dd < 5.0)
      dd_status = "SAFE";
   else if(dd < 10.0)
      dd_status = "CAUTION";
   else if(dd < 15.0)
      dd_status = "WARNING";
   else
      dd_status = "DANGER";
   info += "========================================\n";
   info += "  SAPUAN NONAN XAUUSD PRO v2.0\n";
   info += "========================================\n";
   info += "\n";
   if(g_TradingHalted)
   {
      info += " TRADING HALTED\n";
      info += StringFormat(" Reason: %s\n", g_TradingHaltReason);
      info += "\n";
   }
   info += " ACCOUNT:\n";
   info += StringFormat(" Balance: $%.2f\n", balance);
   info += StringFormat(" Equity: $%.2f\n", equity);
   info += StringFormat(" Floating: $%.2f\n", floating);
   info += StringFormat(" Margin: %.0f%%\n", margin);
   info += "\n";
   info += " DRAWDOWN:\n";
   info += StringFormat(" Current: %.2f%% %s\n", dd, dd_status);
   info += StringFormat(" Limit: %.0f%%\n", iMaxDrawdownPercent);
   info += StringFormat(" Buffer: %.2f%%\n", iMaxDrawdownPercent - dd);
   info += " " + CreateDDBar(dd) + "\n";
   info += "\n";
   if(g_EmergencyMode)
   {
      int min_left = g_EmergencyCooldownMinutes - (int)((TimeCurrent() - g_EmergencyStartTime) / 60);
      info += " EMERGENCY MODE\n";
      info += StringFormat(" Cooldown: %d min\n", min_left);
      info += "\n";
   }
   info += " POSITIONS:\n";
   info += StringFormat(" Buy: %d / %d allowed\n", buy, max);
   info += StringFormat(" Sell: %d / %d allowed\n", sell, max);
   info += "\n";
   info += " MARKET:\n";
   info += StringFormat(" Spread: %d pips\n", spread);
   info += StringFormat(" ATR: %.1f pips\n", atr);
   if(IsLDRDate())
   {
      info += "\n";
      info += " LDR 2026 DATE - CAUTION!\n";
   }
   info += "\n";
   info += " " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + "\n";
   info += "========================================\n";
   Comment(info);
}
//+------------------------------------------------------------------+