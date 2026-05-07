//+------------------------------------------------------------------+
//|                                              Moving Averages.mq5 |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

// ==== Tham số người dùng (có thể chỉnh trong EA inputs) ====
// Số nến trước đó cần kiểm tra (không tính nến hiện tại)
input int  InpLookbackBars  = 50;    
// Sai số chạm vùng giá (points) để xác định có chạm
input int  InpZonePoints    = 30;    
// Độ rộng vùng vẽ (points) cho 2 đường song song
input int  InpDrawPoints    = 6;     
// Số nến LIỀN KỀ phải chạm vùng giá mới đủ điều kiện
input int  InpConsecutiveBars = 20;  

// Kiểm tra chuỗi nến liền kề ngay trước nến anchor.
// - Anchor = nến ngay trước tick hiện tại (shift = 1) -> rates[0].
// - Chỉ khi đủ số nến liền kề chạm vùng giá mới vẽ.
// - Trả về giá vùng (zone_low/zone_high) và thời gian để vẽ đoạn.
bool PreviousBarsTouchedZone(const int lookback_bars,
                              const int zone_points,
                              const int draw_points,
                              const int consecutive_bars,
                              double &zone_low,
                              double &zone_high,
                              datetime &left_time,
                              datetime &right_time)
{
   // Lấy dữ liệu nến liền kề từ nến vừa đóng cửa nhất (shift = 1)
   MqlRates rates[];
   const int need = MathMax(lookback_bars, 2);
   const int copied = CopyRates(_Symbol, _Period, 1, need, rates);

   if(copied < 2)
      return false;

   // Đặt rates[0] là nến gần nhất (shift=1)
   ArraySetAsSeries(rates, true); 
   // Đỉnh giá cao và thấp của nến anchor
   const double anchor_high = rates[0].high; 
   const double anchor_low = rates[0].low;   
   // Sai số chạm vùng giá
   const double tolerance = zone_points * _Point;      
   // Độ rộng vùng vẽ hẹp
   const double draw_tolerance = draw_points * _Point; 
   // Số nến liền kề tối thiểu
   const int required = MathMax(consecutive_bars, 1);  
   if(copied < required + 1)
      return false;

   // Kiểm tra chuỗi liền kề chạm quanh anchor_high
   int touches = 0;
   for(int i = 1; i <= required; ++i)
   {
      // Kiểm tra chạm vùng giá
      if(MathAbs(rates[i].high - anchor_high) <= tolerance ||
         MathAbs(rates[i].low - anchor_high) <= tolerance)
      {
         touches++;
      }
      else
      {
         touches = 0;
         break;
      }
   }

   if(touches >= required)
   {
      // Vẽ đoạn song song
      zone_low = anchor_high - draw_tolerance;
      zone_high = anchor_high + draw_tolerance;
      // Đoạn vẽ chỉ trong khoảng nến liền kề -> từ nến cũ nhất đến anchor
      left_time = rates[required].time;
      right_time = rates[0].time;
      return true;
   }

   // Kiểm tra chuỗi liền kề chạm quanh anchor_low
   touches = 0;
   for(int i = 1; i <= required; ++i)
   {
      // Kiểm tra chạm vùng giá
      if(MathAbs(rates[i].high - anchor_low) <= tolerance ||
         MathAbs(rates[i].low - anchor_low) <= tolerance)
      {
         touches++;
      }
      else
      {
         touches = 0;
         break;
      }
   }

   if(touches >= required)
   {
      // Vẽ đoạn song song
      zone_low = anchor_low - draw_tolerance;
      zone_high = anchor_low + draw_tolerance;
      left_time = rates[required].time;
      right_time = rates[0].time;
      return true;
   }

   return false;
}

// Vẽ đoạn ngang trong khoảng thời gian đủ điều kiện (không kéo dài về trái/phải).
void DrawZoneSegment(const string name,
                     const datetime left_time,
                     const datetime right_time,
                     const double price)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_TREND, 0, left_time, price, right_time, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   }
   else
   {
      ObjectMove(0, name, 0, left_time, price);
      ObjectMove(0, name, 1, right_time, price);
   }
}

void OnTick()
{
   // Kiểm tra điều kiện và vẽ 2 đoạn song song khi đủ điều kiện
   double zone_low = 0.0;
   double zone_high = 0.0;
   datetime left_time = 0;
   datetime right_time = 0;
   const bool touched = PreviousBarsTouchedZone(
      InpLookbackBars,
      InpZonePoints,
      InpDrawPoints,
      InpConsecutiveBars,
      zone_low,
      zone_high,
      left_time,
      right_time
   );

   if(touched)
   {
      DrawZoneSegment("TickZoneHigh", left_time, right_time, zone_high);
      DrawZoneSegment("TickZoneLow", left_time, right_time, zone_low);
      Print("Da co tick truoc do cham cung vung gia.");
   }
   else
   {
      ObjectDelete(0, "TickZoneHigh");
      ObjectDelete(0, "TickZoneLow");
   }
}

