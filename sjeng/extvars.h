/*
    Sjeng - a chess variants playing program
    Copyright (C) 2000 Gian-Carlo Pascutto

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    File: extvars.h                                        
    Purpose: global data definitions

*/

#include <stdint.h>

extern SJENG_THREAD_LOCAL char divider[50];

extern SJENG_THREAD_LOCAL int board[144], moved[144], ep_square, white_to_move, wking_loc,
  bking_loc, white_castled, black_castled, result, ply, pv_length[PV_BUFF],
  squares[144], num_pieces, i_depth, comp_color, fifty, piece_count;

extern SJENG_THREAD_LOCAL int32_t nodes, raw_nodes, qnodes, killer_scores[PV_BUFF],
  killer_scores2[PV_BUFF], killer_scores3[PV_BUFF], moves_to_tc, min_per_game,
  sec_per_game, inc, time_left, opp_time, time_cushion, time_for_move, cur_score;

extern SJENG_THREAD_LOCAL uint32_t history_h[144][144];

extern SJENG_THREAD_LOCAL bool captures, searching_pv, post, time_exit, time_failure;
extern SJENG_THREAD_LOCAL int xb_mode, maxdepth;

extern SJENG_THREAD_LOCAL move_s pv[PV_BUFF][PV_BUFF], dummy, killer1[PV_BUFF], killer2[PV_BUFF],
  killer3[PV_BUFF];

extern SJENG_THREAD_LOCAL  move_x path_x[PV_BUFF];
extern SJENG_THREAD_LOCAL  move_s path[PV_BUFF];
  
extern SJENG_THREAD_LOCAL rtime_t start_time;

extern SJENG_THREAD_LOCAL int holding[2][16];
extern SJENG_THREAD_LOCAL int num_holding[2];

extern SJENG_THREAD_LOCAL int white_hand_eval;
extern SJENG_THREAD_LOCAL int black_hand_eval;

extern SJENG_THREAD_LOCAL int drop_piece;

extern SJENG_THREAD_LOCAL int pieces[62];
extern SJENG_THREAD_LOCAL int is_promoted[62];

extern SJENG_THREAD_LOCAL int num_makemoves;
extern SJENG_THREAD_LOCAL int num_unmakemoves;
extern SJENG_THREAD_LOCAL int num_playmoves;
extern SJENG_THREAD_LOCAL int num_pieceups;
extern SJENG_THREAD_LOCAL int num_piecedowns;
extern SJENG_THREAD_LOCAL int max_moves;

/* piece types range form 0..16 */
extern SJENG_THREAD_LOCAL uint32_t zobrist[17][144];
extern SJENG_THREAD_LOCAL uint32_t hash;

extern SJENG_THREAD_LOCAL uint32_t ECacheProbes;
extern SJENG_THREAD_LOCAL uint32_t ECacheHits;

extern SJENG_THREAD_LOCAL uint32_t TTProbes;
extern SJENG_THREAD_LOCAL uint32_t TTHits;
extern SJENG_THREAD_LOCAL uint32_t TTStores;

extern SJENG_THREAD_LOCAL uint32_t hold_hash;

extern SJENG_THREAD_LOCAL char book[4000][161];
extern SJENG_THREAD_LOCAL int num_book_lines;
extern SJENG_THREAD_LOCAL int book_ply;
extern SJENG_THREAD_LOCAL int use_book;
extern SJENG_THREAD_LOCAL char opening_history[STR_BUFF];
extern SJENG_THREAD_LOCAL uint32_t bookpos[400], booktomove[400], bookidx;

extern SJENG_THREAD_LOCAL int Material;
extern SJENG_THREAD_LOCAL int material[17];
extern SJENG_THREAD_LOCAL int zh_material[17];
extern SJENG_THREAD_LOCAL int std_material[17];
extern SJENG_THREAD_LOCAL int suicide_material[17];
extern SJENG_THREAD_LOCAL int losers_material[17];

extern SJENG_THREAD_LOCAL int NTries, NCuts, TExt;

extern SJENG_THREAD_LOCAL char ponder_input[STR_BUFF];

extern SJENG_THREAD_LOCAL bool is_pondering;

extern SJENG_THREAD_LOCAL uint32_t FH, FHF, PVS, FULL, PVSF;
extern SJENG_THREAD_LOCAL uint32_t ext_check, ext_recap, ext_onerep;
extern SJENG_THREAD_LOCAL uint32_t razor_drop, razor_material;

extern SJENG_THREAD_LOCAL uint32_t total_moves;
extern SJENG_THREAD_LOCAL uint32_t total_movegens;

extern const int rank[144], file[144], diagl[144], diagr[144], sqcolor[144];

extern SJENG_THREAD_LOCAL int Variant;
extern SJENG_THREAD_LOCAL int Giveaway;
extern SJENG_THREAD_LOCAL int forcedwin;

extern SJENG_THREAD_LOCAL bool is_analyzing;

extern SJENG_THREAD_LOCAL char my_partner[STR_BUFF];
extern SJENG_THREAD_LOCAL bool have_partner;
extern SJENG_THREAD_LOCAL bool must_sit;
extern SJENG_THREAD_LOCAL int must_go;
extern SJENG_THREAD_LOCAL bool go_fast;
extern SJENG_THREAD_LOCAL bool piecedead;
extern SJENG_THREAD_LOCAL bool partnerdead;
extern SJENG_THREAD_LOCAL int tradefreely;

extern SJENG_THREAD_LOCAL char true_i_depth;

extern SJENG_THREAD_LOCAL int32_t fixed_time;

extern SJENG_THREAD_LOCAL int hand_value[];

extern SJENG_THREAD_LOCAL int numb_moves;

extern SJENG_THREAD_LOCAL int phase;

SJENG_THREAD_LOCAL FILE *lrn_standard;
SJENG_THREAD_LOCAL FILE *lrn_zh;
SJENG_THREAD_LOCAL FILE *lrn_suicide;
SJENG_THREAD_LOCAL FILE *lrn_losers;
extern SJENG_THREAD_LOCAL int bestmovenum;

extern SJENG_THREAD_LOCAL int ugly_ep_hack;

extern SJENG_THREAD_LOCAL int root_to_move;

extern SJENG_THREAD_LOCAL int kingcap;

extern SJENG_THREAD_LOCAL int pn_time;
extern SJENG_THREAD_LOCAL move_s pn_move;
extern SJENG_THREAD_LOCAL move_s pn_saver;
extern SJENG_THREAD_LOCAL bool kibitzed;
extern SJENG_THREAD_LOCAL int rootlosers[PV_BUFF];
extern SJENG_THREAD_LOCAL int alllosers;
extern SJENG_THREAD_LOCAL int s_threat;

extern SJENG_THREAD_LOCAL int cfg_booklearn;
extern SJENG_THREAD_LOCAL int cfg_devscale;
extern SJENG_THREAD_LOCAL int cfg_razordrop;
extern SJENG_THREAD_LOCAL int cfg_cutdrop;
extern SJENG_THREAD_LOCAL int cfg_futprune;
extern SJENG_THREAD_LOCAL int cfg_onerep;
extern SJENG_THREAD_LOCAL int cfg_recap;
extern SJENG_THREAD_LOCAL int cfg_smarteval;
extern SJENG_THREAD_LOCAL int cfg_attackeval;
extern SJENG_THREAD_LOCAL float cfg_scalefac;
extern SJENG_THREAD_LOCAL int cfg_ksafety[15][9];
extern SJENG_THREAD_LOCAL int cfg_tropism[5][7];
extern SJENG_THREAD_LOCAL int havercfile;
extern SJENG_THREAD_LOCAL int TTSize;
extern SJENG_THREAD_LOCAL int PBSize;
extern SJENG_THREAD_LOCAL int ECacheSize;

extern SJENG_THREAD_LOCAL int my_rating, opp_rating;
extern SJENG_THREAD_LOCAL int userealholdings;
extern SJENG_THREAD_LOCAL char realholdings[255];

extern SJENG_THREAD_LOCAL int move_number;
extern SJENG_THREAD_LOCAL uint32_t hash_history[600];

extern SJENG_THREAD_LOCAL int moveleft;
extern SJENG_THREAD_LOCAL int movetotal;
extern SJENG_THREAD_LOCAL char searching_move[20];

extern SJENG_THREAD_LOCAL char setcode[30];

extern SJENG_THREAD_LOCAL int EGTBProbes;
extern SJENG_THREAD_LOCAL int EGTBHits;
extern SJENG_THREAD_LOCAL int SEGTB;






