/*
 * Saltarín: mini juego "runner" para Tiny Tapeout VGA (versión 1x1)
 * SPDX-License-Identifier: Apache-2.0
 *
 * Un blob rosado corre por un paisaje con parallax y salta cactus.
 * Sin framebuffer: cada pixel se calcula en el momento a partir de unos
 * pocos registros que se actualizan una vez por cuadro.
 *
 *  - Cielo con degradado tramado (Bayer 2x2) y ciclo día/atardecer/noche/amanecer
 *  - Sol que se pone detrás de las montañas, luna y estrellas de noche
 *  - Montañas lejanas con nieve y colinas cercanas, cada capa a distinta velocidad
 *  - Sprite de 16x16 (escalado 2x) con animación de pasos y parpadeo
 *  - Física de salto con gravedad, colisiones y marcador BCD de 2 dígitos
 *
 * ui_in[0] = saltar
 * ui_in[1] = modo manual (apaga el piloto automático)
 */

`default_nettype none

module tt_um_fernandodli_jumpgame(
  input  wire [7:0] ui_in,    // Dedicated inputs
  output wire [7:0] uo_out,   // Dedicated outputs
  input  wire [7:0] uio_in,   // IOs: Input path
  output wire [7:0] uio_out,  // IOs: Output path
  output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
  input  wire       ena,      // always 1 when the design is powered, so you can ignore it
  input  wire       clk,      // clock
  input  wire       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------- VGA
  wire hsync, vsync, video_active;
  wire [9:0] pix_x, pix_y;
  reg  [5:0] col;              // RRGGBB
  wire [1:0] R = video_active ? col[5:4] : 2'b00;
  wire [1:0] G = video_active ? col[3:2] : 2'b00;
  wire [1:0] B = video_active ? col[1:0] : 2'b00;

  // TinyVGA PMOD
  assign uo_out  = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
  assign uio_out = 0;
  assign uio_oe  = 0;

  hvsync_generator hvsync_gen(
    .clk(clk),
    .reset(~rst_n),
    .hsync(hsync),
    .vsync(vsync),
    .display_on(video_active),
    .hpos(pix_x),
    .vpos(pix_y)
  );

  wire btn_jump = ui_in[0];
  wire autopilot = ~ui_in[1];

  localparam [9:0] GROUND = 10'd400;   // primera línea del suelo
  localparam [9:0] PLAYER_X = 10'd96;

  // ------------------------------------------------- estado del juego
  reg [15:0] frame;
  wire [15:0] scroll = {frame[13:0], 2'b00};   // 4 px por cuadro, sin registro extra
  reg  [9:0] lfsr;
  reg [10:0] obs_x;        // con signo: borde izquierdo del cactus
  reg        tall;         // cactus alto (56) o bajo (40)
  reg  [8:0] py;           // altura del jugador sobre el suelo
  reg signed [7:0] vy;     // velocidad vertical
  reg  [5:0] flash;        // cuadros de invulnerabilidad tras un choque
  reg  [7:0] score;        // 2 dígitos BCD

  wire signed [10:0] obs_s = obs_x;
  wire [5:0] obs_h = tall ? 6'd56 : 6'd40;
  wire on_ground = (py == 9'd0) && (vy == 8'sd0);
  wire auto_jump = autopilot && (obs_s >= 11'sd144) && (obs_s < 11'sd168);
  wire jump = on_ground && (btn_jump || auto_jump);
  wire signed [10:0] py_next = $signed({2'b00, py}) + vy;
  wire hit = (flash == 6'd0) && (obs_s < 11'sd122) && (obs_s > 11'sd78) && (py < {3'b000, obs_h});
  wire respawn = (obs_s <= -11'sd24);

  function [7:0] bcd_inc(input [7:0] s);
    begin
      if (s[3:0] != 4'd9) bcd_inc = {s[7:4], s[3:0] + 4'd1};
      else bcd_inc = {(s[7:4] == 4'd9) ? 4'd0 : s[7:4] + 4'd1, 4'd0};
    end
  endfunction

  wire tick = (pix_x == 10'd0) && (pix_y == 10'd480);   // inicio del vblank

  always @(posedge clk) begin
    if (~rst_n) begin
      frame <= 0; lfsr <= 10'h2E1;
      obs_x <= 11'd640; tall <= 0;
      py <= 0; vy <= 0; flash <= 0; score <= 0;
    end else if (tick) begin
      frame  <= frame + 1;
      lfsr   <= {lfsr[8:0], lfsr[9] ^ lfsr[6]};

      // jugador
      if (on_ground) begin
        if (jump) vy <= 8'sd14;
      end else if (py_next <= 11'sd0) begin
        py <= 0; vy <= 0;
      end else begin
        py <= py_next[8:0]; vy <= vy - 8'sd1;
      end

      // cactus
      if (respawn) begin
        obs_x <= 11'd640 + {3'b000, lfsr[7:0]};
        tall  <= lfsr[8];
      end else begin
        obs_x <= obs_x - 11'd4;
      end

      // choque / puntaje
      if (hit) begin
        flash <= 6'd60; score <= 0;
      end else begin
        if (flash != 0) flash <= flash - 1;
        if (respawn) score <= bcd_inc(score);
      end
    end
  end

  // ------------------------------------------------------ fase del día
  wire [1:0] phase = frame[11:10];      // 0 día, 1 atardecer, 2 noche, 3 amanecer
  wire [7:0] ptime = frame[9:2];
  wire night = (phase == 2'd2);

  // ----------------------------------------------------------- cielo
  wire [2:0] band = pix_y[8:6];
  wire [1:0] sub  = pix_y[5:4];
  wire [1:0] bay  = {pix_x[0] ^ pix_y[0], pix_y[0]};
  wire [2:0] bidx = band + {2'b00, (sub > bay)};

  function [5:0] sky_col(input [1:0] ph, input [2:0] i);
    case ({ph, i})
      // día
      5'd0:  sky_col = 6'b00_01_11; 5'd1:  sky_col = 6'b00_01_11;
      5'd2:  sky_col = 6'b01_10_11; 5'd3:  sky_col = 6'b01_10_11;
      5'd4:  sky_col = 6'b10_11_11; 5'd5:  sky_col = 6'b10_11_11;
      5'd6:  sky_col = 6'b11_11_11; 5'd7:  sky_col = 6'b11_11_11;
      // atardecer
      5'd8:  sky_col = 6'b01_00_10; 5'd9:  sky_col = 6'b10_00_10;
      5'd10: sky_col = 6'b11_00_01; 5'd11: sky_col = 6'b11_01_01;
      5'd12: sky_col = 6'b11_10_00; 5'd13: sky_col = 6'b11_10_00;
      5'd14: sky_col = 6'b11_11_01; 5'd15: sky_col = 6'b11_11_01;
      // noche
      5'd16: sky_col = 6'b00_00_01; 5'd17: sky_col = 6'b00_00_01;
      5'd18: sky_col = 6'b00_00_01; 5'd19: sky_col = 6'b00_00_10;
      5'd20: sky_col = 6'b00_01_10; 5'd21: sky_col = 6'b01_01_10;
      5'd22: sky_col = 6'b01_01_10; 5'd23: sky_col = 6'b01_01_10;
      // amanecer
      5'd24: sky_col = 6'b00_01_10; 5'd25: sky_col = 6'b01_01_10;
      5'd26: sky_col = 6'b10_01_10; 5'd27: sky_col = 6'b11_10_10;
      5'd28: sky_col = 6'b11_10_01; 5'd29: sky_col = 6'b11_11_01;
      5'd30: sky_col = 6'b11_11_10; default: sky_col = 6'b11_11_10;
    endcase
  endfunction

  // estrellas: hash barato de la posición en celdas de 2x2
  wire [7:0] sx8 = pix_x[9:2];
  wire [7:0] sy8 = pix_y[8:1];
  wire [7:0] ssum = sx8 + sy8;
  wire [7:0] star_h = {sx8[4:0], sx8[7:5]} ^ sy8 ^ (sx8 & {sy8[3:0], sy8[7:4]});
  wire star = night && (star_h == 8'hA5) && !pix_x[1];
  wire star_dim = frame[5] ^ sx8[0] ^ sy8[1];     // titileo

  // -------------------------------------------------------- sol / luna
  reg [9:0] sun_y;
  always @(*) begin
    case (phase)
      2'd1:    sun_y = 10'd90 + {2'b00, ptime};    // se pone
      2'd3:    sun_y = 10'd345 - {2'b00, ptime};   // sale
      default: sun_y = 10'd90;
    endcase
  end
  // Caja de 64x64 alrededor del sol; dentro de la caja, el espejo de bits
  // (dx[5] ? dx[4:0] : ~dx[4:0]) da la distancia al centro sin restar.
  wire [9:0] sdx = pix_x - 10'd448;               // centro x = 480
  wire [9:0] sdy = pix_y - (sun_y - 10'd32);      // centro y = sun_y
  wire [4:0] sax = sdx[5] ? sdx[4:0] : ~sdx[4:0];
  wire [4:0] say = sdy[5] ? sdy[4:0] : ~sdy[4:0];
  wire [5:0] sad = {1'b0, sax} + {1'b0, say};
  wire sun = (sdx[9:6] == 4'd0) && (sdy[9:6] == 4'd0) && (sad < 6'd42) &&
             (sax < 5'd28) && (say < 5'd28);

  // ---------------------------------------------------------- nubes
  wire [9:0] c1x = pix_x + scroll[12:3];          // 1/8 de velocidad
  function cloud(input [9:0] lx, input [9:0] ly);
    cloud = (lx < 10'd96 && ly >= 10'd16 && ly < 10'd32) ||
            (lx >= 10'd16 && lx < 10'd80 && ly >= 10'd8 && ly < 10'd16) ||
            (lx >= 10'd32 && lx < 10'd64 && ly < 10'd8);
  endfunction
  wire clouds = cloud(c1x - 10'd200, pix_y - 10'd56);

  // ------------------------------------------------------- montañas
  wire [9:0] mx = pix_x + scroll[11:2];           // 1/4 de velocidad
  wire [6:0] tw1 = mx[7] ? ~mx[6:0] : mx[6:0];
  wire [4:0] tw2 = mx[5] ? ~mx[4:0] : mx[4:0];
  wire [9:0] ftop = 10'd330 - {3'b000, tw1} + {6'b0, tw2[4:1]};
  wire far_m = (pix_y >= ftop);
  wire snow  = far_m && (pix_y < 10'd250);

  wire [9:0] hx = pix_x + scroll[10:1];           // 1/2 de velocidad
  wire [5:0] tw3 = hx[6] ? ~hx[5:0] : hx[5:0];
  wire [9:0] ntop = 10'd375 - {4'b0000, tw3};
  wire near_h = (pix_y >= ntop);

  // ---------------------------------------------------------- suelo
  wire [9:0] gx = pix_x + scroll[9:0];            // velocidad completa
  wire ground = (pix_y >= GROUND);
  wire grass  = (pix_y < 10'd404) || ((pix_y < 10'd408) && gx[2]);
  wire [9:0] gd = gx + pix_y;
  wire dirt_l = gd[4];

  // ---------------------------------------------------------- cactus
  wire [10:0] lx = {1'b0, pix_x} - obs_x;
  wire [9:0]  ly = 10'd399 - pix_y;
  wire in_air = (pix_y < GROUND);
  wire cactus = in_air && (
      (lx >= 11'd8  && lx < 11'd16 && ly < {4'b0, obs_h}) ||
      (lx < 11'd4   && ly >= 10'd20 && ly < 10'd36) ||
      (lx >= 11'd4  && lx < 11'd8  && ly >= 10'd20 && ly < 10'd24) ||
      (lx >= 11'd20 && lx < 11'd24 && ly >= 10'd14 && ly < 10'd30) ||
      (lx >= 11'd16 && lx < 11'd20 && ly >= 10'd14 && ly < 10'd18));
  wire cactus_hi = (lx[1:0] == 2'd2);

  // ---------------------------------------------------------- jugador
  function [31:0] sprite_row(input [1:0] var_, input [3:0] row);
    case ({var_, row})
      6'd0: sprite_row = 32'h00aaaa00;
      6'd1: sprite_row = 32'h0a5555a0;
      6'd2: sprite_row = 32'h25555558;
      6'd3: sprite_row = 32'h25555558;
      6'd4: sprite_row = 32'h2f57d556;
      6'd5: sprite_row = 32'h2b56d556;
      6'd6: sprite_row = 32'h95555556;
      6'd7: sprite_row = 32'h96555556;
      6'd8: sprite_row = 32'h96a55556;
      6'd9: sprite_row = 32'h95555556;
      6'd10: sprite_row = 32'h25555558;
      6'd11: sprite_row = 32'h25555558;
      6'd12: sprite_row = 32'h0a5555a0;
      6'd13: sprite_row = 32'h00aaaa00;
      6'd14: sprite_row = 32'h00a00a00;
      6'd15: sprite_row = 32'h00a80a80;
      6'd16: sprite_row = 32'h00aaaa00;
      6'd17: sprite_row = 32'h0a5555a0;
      6'd18: sprite_row = 32'h25555558;
      6'd19: sprite_row = 32'h25555558;
      6'd20: sprite_row = 32'h2f57d556;
      6'd21: sprite_row = 32'h2b56d556;
      6'd22: sprite_row = 32'h95555556;
      6'd23: sprite_row = 32'h96555556;
      6'd24: sprite_row = 32'h96a55556;
      6'd25: sprite_row = 32'h95555556;
      6'd26: sprite_row = 32'h25555558;
      6'd27: sprite_row = 32'h25555558;
      6'd28: sprite_row = 32'h0a5555a0;
      6'd29: sprite_row = 32'h00aaaa00;
      6'd30: sprite_row = 32'h02800280;
      6'd31: sprite_row = 32'h02a002a0;
      6'd32: sprite_row = 32'h00aaaa00;
      6'd33: sprite_row = 32'h0a5555a0;
      6'd34: sprite_row = 32'h25555558;
      6'd35: sprite_row = 32'h25555558;
      6'd36: sprite_row = 32'h2f57d556;
      6'd37: sprite_row = 32'h2b56d556;
      6'd38: sprite_row = 32'h95555556;
      6'd39: sprite_row = 32'h96555556;
      6'd40: sprite_row = 32'h96a55556;
      6'd41: sprite_row = 32'h95555556;
      6'd42: sprite_row = 32'h25555558;
      6'd43: sprite_row = 32'h25555558;
      6'd44: sprite_row = 32'h0a5555a0;
      6'd45: sprite_row = 32'h00aaaa00;
      6'd46: sprite_row = 32'h0a0000a0;
      6'd47: sprite_row = 32'h00000000;
      default: sprite_row = 32'h0;
    endcase
  endfunction
  wire [9:0] ptop = 10'd368 - {1'b0, py};
  wire [9:0] psx = pix_x - PLAYER_X;
  wire [9:0] psy = pix_y - ptop;
  wire [1:0] pvar = (py != 0) ? 2'd2 : {1'b0, frame[2]};
  wire [31:0] prow = sprite_row(pvar, psy[4:1]);
  wire [1:0] pcode_raw = prow[{psx[4:1], 1'b0} +: 2];
  wire blink = (frame[7:3] == 5'd0);
  reg  [1:0] pcode;
  always @(*) begin
    pcode = pcode_raw;
    if (blink && psy[4:1] == 4'd4 && pcode_raw == 2'd3) pcode = 2'd1;
    if (blink && psy[4:1] == 4'd5 && pcode_raw == 2'd3) pcode = 2'd2;
  end
  wire player = (psx < 10'd32) && (psy < 10'd32) && (pcode != 2'd0) &&
                !((flash != 6'd0) && flash[2]);

  // -------------------------------------------------------- marcador
  wire [9:0] dsx = pix_x - 10'd24;
  wire [9:0] dsy = pix_y - 10'd20;
  wire didx = dsx[5];
  wire [4:0] ddx = dsx[4:0];
  wire [5:0] ddy = dsy[5:0];
  reg  [3:0] dval;
  always @(*) begin
    dval = didx ? score[3:0] : score[7:4];
  end
  reg [6:0] segs;   // gfedcba
  always @(*) begin
    case (dval)
      4'd0: segs = 7'b0111111; 4'd1: segs = 7'b0000110;
      4'd2: segs = 7'b1011011; 4'd3: segs = 7'b1001111;
      4'd4: segs = 7'b1100110; 4'd5: segs = 7'b1101101;
      4'd6: segs = 7'b1111101; 4'd7: segs = 7'b0000111;
      4'd8: segs = 7'b1111111; default: segs = 7'b1101111;
    endcase
  end
  wire hmid = (ddx >= 5'd4) && (ddx < 5'd16);
  wire digit_on = (dsx < 10'd64) && (dsy < 10'd36) && (
      (segs[0] && hmid && ddy < 6'd4) ||
      (segs[1] && ddx >= 5'd16 && ddx < 5'd20 && ddy >= 6'd4 && ddy < 6'd18) ||
      (segs[2] && ddx >= 5'd16 && ddx < 5'd20 && ddy >= 6'd18 && ddy < 6'd32) ||
      (segs[3] && hmid && ddy >= 6'd32) ||
      (segs[4] && ddx < 5'd4 && ddy >= 6'd18 && ddy < 6'd32) ||
      (segs[5] && ddx < 5'd4 && ddy >= 6'd4 && ddy < 6'd18) ||
      (segs[6] && hmid && ddy >= 6'd16 && ddy < 6'd20));

  // --------------------------------------------------- composición
  always @(*) begin
    if (digit_on)
      col = night ? 6'b11_11_10 : 6'b11_11_11;
    else if (player)
      case (pcode)
        2'd1:    col = (flash != 0) ? 6'b11_00_00 : 6'b11_01_10;
        2'd2:    col = 6'b01_00_01;
        default: col = 6'b11_11_11;
      endcase
    else if (cactus)
      col = cactus_hi ? 6'b01_11_01 : 6'b00_10_00;
    else if (ground)
      col = grass ? (night ? 6'b00_01_00 : 6'b00_10_00)
                  : (dirt_l ? (night ? 6'b01_00_00 : 6'b10_01_00)
                            : (night ? 6'b00_00_00 : 6'b01_01_00));
    else if (near_h)
      case (phase)
        2'd0: col = 6'b00_10_01;  2'd1: col = 6'b01_01_00;
        2'd2: col = 6'b00_01_00;  default: col = 6'b00_01_01;
      endcase
    else if (far_m)
      if (snow) col = night ? 6'b01_01_10 : 6'b11_11_11;
      else case (phase)
        2'd0: col = 6'b01_01_10;  2'd1: col = 6'b10_00_01;
        2'd2: col = 6'b00_00_01;  default: col = 6'b01_00_10;
      endcase
    else if (clouds)
      case (phase)
        2'd0: col = 6'b11_11_11;  2'd1: col = 6'b11_10_10;
        2'd2: col = 6'b01_01_10;  default: col = 6'b11_10_11;
      endcase
    else if (sun)
      case (phase)
        2'd0: col = 6'b11_11_01;  2'd1: col = 6'b11_10_00;
        2'd2: col = 6'b11_11_10;  default: col = 6'b11_10_01;
      endcase
    else if (star)
      col = star_dim ? 6'b10_10_10 : 6'b11_11_11;
    else
      col = sky_col(phase, bidx);
  end

  // Suppress unused signals warning
  wire _unused_ok = &{ena, ui_in[7:2], uio_in, frame[15:14], scroll[1:0], scroll[15:14], lfsr[9],
                      py_next[10:9], gd[9:5], gd[3:0], c1x, ly, lx[10:2], dsy[9:6], dsx[9:6]};

endmodule