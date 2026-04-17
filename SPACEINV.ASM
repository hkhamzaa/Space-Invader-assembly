; =================================================================
;  SPACEINV.ASM   -   Space Invaders (MASM 6.x / Intel 8086 / DOSBox)
; -----------------------------------------------------------------
;  Strict 8086 real-mode.  80x25 text mode, direct VRAM @ B800h.
;  BIOS INT 10h for mode set and cursor, INT 16h for keyboard,
;  BIOS tick counter at 0040:006Ch for frame timing.
;
;  Build:
;       masm SPACEINV.ASM;
;       link SPACEINV.OBJ;
;       SPACEINV
;
;  Architecture (high level):
;       main           - sets mode, runs title/game/gameover states
;       TitleScreen    - waits for ENTER
;       ResetGame      - re-initialises all game state
;       game_loop      - one iteration per BIOS tick (~18 Hz)
;           HandleInput        (INT 16h, non-blocking)
;           UpdatePlayerBullet (moves the single player bullet up)
;           MoveEnemies        (shared offset, bounce left/right)
;           UpdateEnemyBullets (moves enemy bullets down)
;           SpawnEnemyBullet   (random alive enemy fires)
;           CheckCollisions    (player bullet vs enemies,
;                               enemy bullets vs player)
;           CheckRespawn       (3-second respawn per slot)
;           RenderFrame        (clear VRAM, draw HUD/enemies/player/bullets)
;       GameOverScreen - waits for R (restart) or Q (quit)
; =================================================================

.MODEL small
.8086
.STACK 200h

; ---- constants ---------------------------------------------------
VIDEO_SEG       EQU 0B800h
PLAYER_ROW      EQU 22
ENEMY_ROW       EQU 3
NUM_ENEMIES     EQU 4
NUM_EBULLETS    EQU 5

ATTR_NORMAL     EQU 07h         ; white on black
ATTR_PLAYER     EQU 0Eh         ; yellow
ATTR_ENEMY      EQU 0Ch         ; light red
ATTR_PBULLET    EQU 0Bh         ; light cyan
ATTR_EBULLET    EQU 0Ah         ; light green
ATTR_HUD        EQU 0Fh         ; bright white
ATTR_TITLE      EQU 0Eh         ; yellow
ATTR_GOVER      EQU 0Ch         ; light red

KEY_LEFT        EQU 4Bh
KEY_RIGHT       EQU 4Dh
KEY_SPACE       EQU 39h
KEY_Q           EQU 10h
KEY_R           EQU 13h
KEY_ENTER       EQU 1Ch

ENEMY_MOVE_RATE EQU 4            ; enemies step every 4 frames
ENEMY_FIRE_RATE EQU 12           ; enemy bullet spawn every 12 frames
RESPAWN_FRAMES  EQU 54           ; ~3 seconds at 18.2 Hz

; ---- data --------------------------------------------------------
.DATA

player_x        db 40
player_bx       db 0
player_by       db 0
player_b_act    db 0

enemy_base_x    db 10, 30, 50, 70
enemy_alive     db 1, 1, 1, 1
enemy_resp_t    db 0, 0, 0, 0
enemy_ofs       db 0             ; signed horizontal offset
enemy_dir       db 1             ; +1 or -1
enemy_mv_timer  db 0
enemy_fr_timer  db 0

ebull_x         db 0,0,0,0,0
ebull_y         db 0,0,0,0,0
ebull_act       db 0,0,0,0,0

score           db 3
want_quit       db 0
want_restart    db 0

rand_seed       dw 0BEEFh
last_tick       dw 0

m_title         db 'SPACE INVADERS',0
m_ctl1          db 'Left Arrow  = Move Left',0
m_ctl2          db 'Right Arrow = Move Right',0
m_ctl3          db 'Space       = Fire',0
m_ctl4          db 'Q           = Quit',0
m_press         db 'Press ENTER to Start',0
m_score         db 'Score: ',0
m_gover         db 'GAME OVER',0
m_final         db 'Final Score: ',0
m_opts          db 'R = Restart     Q = Quit',0

; ---- code --------------------------------------------------------
.CODE

; =================================================================
;  main
; =================================================================
main PROC
        mov     ax, @data
        mov     ds, ax

        mov     ax, 0003h       ; 80x25 colour text, clear screen
        int     10h
        call    HideCursor

main_start:
        call    TitleScreen
        cmp     want_quit, 1
        je      quit_game

play_start:
        call    ResetGame

game_loop:
        call    WaitTick
        call    HandleInput
        cmp     want_quit, 1
        je      quit_game

        call    UpdatePlayerBullet
        call    MoveEnemies
        call    UpdateEnemyBullets
        call    SpawnEnemyBullet
        call    CheckCollisions
        call    CheckRespawn
        call    RenderFrame

        cmp     score, 0
        jg      game_loop

        call    GameOverScreen
        cmp     want_quit, 1
        je      quit_game
        cmp     want_restart, 1
        je      play_start
        jmp     main_start

quit_game:
        call    ShowCursor
        mov     ax, 0003h
        int     10h
        mov     ax, 4C00h
        int     21h
main ENDP

; =================================================================
;  HideCursor / ShowCursor
; =================================================================
HideCursor PROC
        push    ax
        push    cx
        mov     ah, 01h
        mov     cx, 2607h        ; bit 5 of CH => cursor off
        int     10h
        pop     cx
        pop     ax
        ret
HideCursor ENDP

ShowCursor PROC
        push    ax
        push    cx
        mov     ah, 01h
        mov     cx, 0607h        ; standard scan lines
        int     10h
        pop     cx
        pop     ax
        ret
ShowCursor ENDP

; =================================================================
;  WaitTick - blocks until BIOS tick counter changes (~18 Hz)
; =================================================================
WaitTick PROC
        push    ax
        push    es
wt_loop:
        xor     ax, ax
        mov     es, ax
        mov     ax, es:[046Ch]
        cmp     ax, last_tick
        je      wt_loop
        mov     last_tick, ax
        pop     es
        pop     ax
        ret
WaitTick ENDP

; =================================================================
;  ClearScreen - fills B800h with space char, normal attribute
; =================================================================
ClearScreen PROC
        push    ax
        push    cx
        push    di
        push    es
        mov     ax, VIDEO_SEG
        mov     es, ax
        xor     di, di
        mov     ax, 0720h        ; attr 07h + space (20h)
        mov     cx, 2000         ; 80*25 cells
        cld
        rep     stosw
        pop     es
        pop     di
        pop     cx
        pop     ax
        ret
ClearScreen ENDP

; =================================================================
;  PutChar - draw a single character
;  In: DL=col, DH=row, AL=char, BH=attribute
;  Preserves all registers.
; =================================================================
PutChar PROC
        push    ax
        push    bx
        push    cx
        push    dx
        push    di
        push    es
        mov     bl, al           ; BX = attr:char
        mov     al, dh
        mov     cl, 80
        mul     cl               ; AX = row*80
        mov     cl, dl
        xor     ch, ch
        add     ax, cx           ; AX = row*80 + col
        shl     ax, 1            ; *2 bytes per cell
        mov     di, ax
        mov     ax, VIDEO_SEG
        mov     es, ax
        mov     es:[di], bx
        pop     es
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
PutChar ENDP

; =================================================================
;  DrawString
;  In: DL=col, DH=row, SI=ASCIZ string, BH=attribute
; =================================================================
DrawString PROC
        push    ax
        push    dx
        push    si
ds_loop:
        mov     al, [si]
        or      al, al
        jz      ds_done
        call    PutChar
        inc     si
        inc     dl
        jmp     ds_loop
ds_done:
        pop     si
        pop     dx
        pop     ax
        ret
DrawString ENDP

; =================================================================
;  DrawNum2 - print AL as 2-digit decimal
;  In: DL=col, DH=row, AL=num (0..99), BH=attribute
; =================================================================
DrawNum2 PROC
        push    ax
        push    cx
        push    dx
        xor     ah, ah
        mov     cl, 10
        div     cl               ; AL=tens, AH=ones
        push    ax
        add     al, '0'
        call    PutChar
        inc     dl
        pop     ax
        mov     al, ah
        add     al, '0'
        call    PutChar
        pop     dx
        pop     cx
        pop     ax
        ret
DrawNum2 ENDP

; =================================================================
;  HandleInput - drains the keyboard buffer (non-blocking)
; =================================================================
HandleInput PROC
        push    ax
hi_loop:
        mov     ah, 01h
        int     16h
        jz      hi_done
        mov     ah, 00h
        int     16h

        cmp     ah, KEY_LEFT
        je      hi_left
        cmp     ah, KEY_RIGHT
        je      hi_right
        cmp     ah, KEY_SPACE
        je      hi_fire
        cmp     al, ' '
        je      hi_fire
        cmp     ah, KEY_Q
        je      hi_quit
        cmp     al, 'q'
        je      hi_quit
        cmp     al, 'Q'
        je      hi_quit
        jmp     hi_loop

hi_left:
        cmp     byte ptr player_x, 2
        jbe     hi_loop
        dec     byte ptr player_x
        jmp     hi_loop

hi_right:
        cmp     byte ptr player_x, 77
        jae     hi_loop
        inc     byte ptr player_x
        jmp     hi_loop

hi_fire:
        cmp     byte ptr player_b_act, 1
        je      hi_loop
        mov     al, player_x
        mov     player_bx, al
        mov     al, PLAYER_ROW - 1
        mov     player_by, al
        mov     byte ptr player_b_act, 1
        jmp     hi_loop

hi_quit:
        mov     byte ptr want_quit, 1
hi_done:
        pop     ax
        ret
HandleInput ENDP

; =================================================================
;  UpdatePlayerBullet - bullet ascends one row per frame
; =================================================================
UpdatePlayerBullet PROC
        cmp     byte ptr player_b_act, 0
        je      upb_done
        dec     byte ptr player_by
        cmp     byte ptr player_by, 1
        jae     upb_done
        mov     byte ptr player_b_act, 0
upb_done:
        ret
UpdatePlayerBullet ENDP

; =================================================================
;  UpdateEnemyBullets - descend one row per frame
; =================================================================
UpdateEnemyBullets PROC
        push    ax
        push    si
        xor     si, si
ueb_loop:
        cmp     si, NUM_EBULLETS
        jae     ueb_done
        cmp     byte ptr [ebull_act + si], 0
        je      ueb_next
        inc     byte ptr [ebull_y + si]
        mov     al, [ebull_y + si]
        cmp     al, 24
        jb      ueb_next
        mov     byte ptr [ebull_act + si], 0
ueb_next:
        inc     si
        jmp     ueb_loop
ueb_done:
        pop     si
        pop     ax
        ret
UpdateEnemyBullets ENDP

; =================================================================
;  MoveEnemies - shared horizontal offset, bounce at edges.
;  Enemies NEVER move vertically.
; =================================================================
MoveEnemies PROC
        push    ax
        push    bx
        inc     byte ptr enemy_mv_timer
        mov     al, enemy_mv_timer
        cmp     al, ENEMY_MOVE_RATE
        jb      me_done
        mov     byte ptr enemy_mv_timer, 0

        mov     al, enemy_ofs
        mov     bl, enemy_dir
        add     al, bl
        cmp     al, 9                    ; OFS_MAX
        jle     me_check_min
        neg     bl                       ; hit right edge - reverse
        mov     enemy_dir, bl
        mov     al, enemy_ofs
        add     al, bl
        jmp     me_store
me_check_min:
        cmp     al, -9                   ; OFS_MIN
        jge     me_store
        neg     bl                       ; hit left edge - reverse
        mov     enemy_dir, bl
        mov     al, enemy_ofs
        add     al, bl
me_store:
        mov     enemy_ofs, al
me_done:
        pop     bx
        pop     ax
        ret
MoveEnemies ENDP

; =================================================================
;  Rand - 16-bit LCG, result in AX
; =================================================================
Rand PROC
        push    bx
        push    dx
        mov     ax, rand_seed
        mov     bx, 25173
        mul     bx
        add     ax, 13849
        mov     rand_seed, ax
        pop     dx
        pop     bx
        ret
Rand ENDP

; =================================================================
;  SpawnEnemyBullet - periodically have a random alive enemy fire
; =================================================================
SpawnEnemyBullet PROC
        push    ax
        push    bx
        push    cx
        push    si
        inc     byte ptr enemy_fr_timer
        mov     al, enemy_fr_timer
        cmp     al, ENEMY_FIRE_RATE
        jb      seb_done
        mov     byte ptr enemy_fr_timer, 0

        xor     si, si
seb_find:
        cmp     si, NUM_EBULLETS
        jae     seb_done                 ; no free bullet slot
        cmp     byte ptr [ebull_act + si], 0
        je      seb_got_slot
        inc     si
        jmp     seb_find

seb_got_slot:
        call    Rand
        and     ax, 3
        mov     bx, ax
        mov     cx, NUM_ENEMIES
seb_find_alive:
        or      cx, cx
        jz      seb_done                 ; no enemies alive
        cmp     byte ptr [enemy_alive + bx], 0
        jne     seb_alive_found
        inc     bx
        and     bx, 3
        dec     cx
        jmp     seb_find_alive

seb_alive_found:
        mov     al, [enemy_base_x + bx]
        add     al, enemy_ofs
        mov     [ebull_x + si], al
        mov     al, ENEMY_ROW + 1
        mov     [ebull_y + si], al
        mov     byte ptr [ebull_act + si], 1
seb_done:
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret
SpawnEnemyBullet ENDP

; =================================================================
;  CheckCollisions
;   A) player bullet at row ENEMY_ROW vs any alive enemy
;   B) each enemy bullet at PLAYER_ROW vs the 3-char player sprite
; =================================================================
CheckCollisions PROC
        push    ax
        push    bx
        push    dx
        push    si

        ; --- A: player bullet vs enemies ---
        cmp     byte ptr player_b_act, 0
        je      cc_ebulls
        mov     al, player_by
        cmp     al, ENEMY_ROW
        jne     cc_ebulls
        mov     dl, player_bx
        xor     si, si
cc_e_loop:
        cmp     si, NUM_ENEMIES
        jae     cc_ebulls
        cmp     byte ptr [enemy_alive + si], 0
        je      cc_e_next
        mov     al, [enemy_base_x + si]
        add     al, enemy_ofs
        cmp     al, dl
        jne     cc_e_next
        ; HIT
        mov     byte ptr [enemy_alive + si], 0
        mov     byte ptr [enemy_resp_t + si], RESPAWN_FRAMES
        mov     byte ptr player_b_act, 0
        inc     byte ptr score
        jmp     cc_ebulls
cc_e_next:
        inc     si
        jmp     cc_e_loop

        ; --- B: enemy bullets vs player ---
cc_ebulls:
        xor     si, si
cc_p_loop:
        cmp     si, NUM_EBULLETS
        jae     cc_done
        cmp     byte ptr [ebull_act + si], 0
        je      cc_p_next
        mov     al, [ebull_y + si]
        cmp     al, PLAYER_ROW
        jne     cc_p_next
        mov     al, [ebull_x + si]
        mov     bl, player_x
        dec     bl                       ; left edge of sprite
        cmp     al, bl
        jb      cc_p_next
        add     bl, 2                    ; right edge of sprite
        cmp     al, bl
        ja      cc_p_next
        ; HIT
        mov     byte ptr [ebull_act + si], 0
        cmp     byte ptr score, 1
        jl      cc_p_next                ; already at zero, skip dec
        dec     byte ptr score
cc_p_next:
        inc     si
        jmp     cc_p_loop
cc_done:
        pop     si
        pop     dx
        pop     bx
        pop     ax
        ret
CheckCollisions ENDP

; =================================================================
;  CheckRespawn - tick down respawn timers, revive when 0
; =================================================================
CheckRespawn PROC
        push    ax
        push    si
        xor     si, si
cr_loop:
        cmp     si, NUM_ENEMIES
        jae     cr_done
        cmp     byte ptr [enemy_alive + si], 1
        je      cr_next
        cmp     byte ptr [enemy_resp_t + si], 0
        je      cr_next
        dec     byte ptr [enemy_resp_t + si]
        cmp     byte ptr [enemy_resp_t + si], 0
        jne     cr_next
        mov     byte ptr [enemy_alive + si], 1
cr_next:
        inc     si
        jmp     cr_loop
cr_done:
        pop     si
        pop     ax
        ret
CheckRespawn ENDP

; =================================================================
;  ResetGame - full reset of every piece of state
; =================================================================
ResetGame PROC
        push    ax
        push    si
        mov     byte ptr player_x,       40
        mov     byte ptr player_b_act,   0
        mov     byte ptr player_bx,      0
        mov     byte ptr player_by,      0
        mov     byte ptr score,          3
        mov     byte ptr enemy_ofs,      0
        mov     byte ptr enemy_dir,      1
        mov     byte ptr enemy_mv_timer, 0
        mov     byte ptr enemy_fr_timer, 0
        mov     byte ptr want_quit,      0
        mov     byte ptr want_restart,   0

        xor     si, si
rg_e:
        cmp     si, NUM_ENEMIES
        jae     rg_e_end
        mov     byte ptr [enemy_alive  + si], 1
        mov     byte ptr [enemy_resp_t + si], 0
        inc     si
        jmp     rg_e
rg_e_end:

        xor     si, si
rg_b:
        cmp     si, NUM_EBULLETS
        jae     rg_b_end
        mov     byte ptr [ebull_act + si], 0
        mov     byte ptr [ebull_x   + si], 0
        mov     byte ptr [ebull_y   + si], 0
        inc     si
        jmp     rg_b
rg_b_end:
        pop     si
        pop     ax
        ret
ResetGame ENDP

; =================================================================
;  RenderFrame - clear and repaint everything
; =================================================================
RenderFrame PROC
        call    ClearScreen
        call    DrawHUD
        call    DrawEnemies
        call    DrawPlayer
        call    DrawBullets
        ret
RenderFrame ENDP

; ---- DrawHUD -----------------------------------------------------
DrawHUD PROC
        push    ax
        push    bx
        push    dx
        push    si
        mov     bh, ATTR_HUD
        mov     dl, 2
        mov     dh, 0
        mov     si, OFFSET m_score
        call    DrawString
        mov     dl, 9
        mov     dh, 0
        mov     al, score
        cmp     al, 0
        jge     dh_ok
        xor     al, al
dh_ok:
        mov     bh, ATTR_HUD
        call    DrawNum2
        pop     si
        pop     dx
        pop     bx
        pop     ax
        ret
DrawHUD ENDP

; ---- DrawEnemies -------------------------------------------------
DrawEnemies PROC
        push    ax
        push    bx
        push    dx
        push    si
        xor     si, si
de_loop:
        cmp     si, NUM_ENEMIES
        jae     de_done
        cmp     byte ptr [enemy_alive + si], 0
        je      de_next
        mov     al, [enemy_base_x + si]
        add     al, enemy_ofs
        mov     dl, al
        mov     dh, ENEMY_ROW
        mov     al, 'W'
        mov     bh, ATTR_ENEMY
        call    PutChar
de_next:
        inc     si
        jmp     de_loop
de_done:
        pop     si
        pop     dx
        pop     bx
        pop     ax
        ret
DrawEnemies ENDP

; ---- DrawPlayer - 3-char sprite "[A]" centred on player_x --------
DrawPlayer PROC
        push    ax
        push    bx
        push    dx
        mov     bh, ATTR_PLAYER
        mov     dh, PLAYER_ROW
        mov     dl, player_x
        dec     dl
        mov     al, '['
        call    PutChar
        inc     dl
        mov     al, 'A'
        call    PutChar
        inc     dl
        mov     al, ']'
        call    PutChar
        pop     dx
        pop     bx
        pop     ax
        ret
DrawPlayer ENDP

; ---- DrawBullets -------------------------------------------------
DrawBullets PROC
        push    ax
        push    bx
        push    dx
        push    si
        cmp     byte ptr player_b_act, 0
        je      db_no_pb
        mov     dl, player_bx
        mov     dh, player_by
        mov     al, '|'
        mov     bh, ATTR_PBULLET
        call    PutChar
db_no_pb:
        xor     si, si
db_eloop:
        cmp     si, NUM_EBULLETS
        jae     db_edone
        cmp     byte ptr [ebull_act + si], 0
        je      db_enext
        mov     dl, [ebull_x + si]
        mov     dh, [ebull_y + si]
        mov     al, '|'
        mov     bh, ATTR_EBULLET
        call    PutChar
db_enext:
        inc     si
        jmp     db_eloop
db_edone:
        pop     si
        pop     dx
        pop     bx
        pop     ax
        ret
DrawBullets ENDP

; =================================================================
;  TitleScreen - blocks until ENTER (or Q to quit)
; =================================================================
TitleScreen PROC
        push    ax
        push    bx
        push    dx
        push    si
        call    ClearScreen

        mov     bh, ATTR_TITLE
        mov     dh, 7
        mov     dl, 33                   ; centre of 14-char title
        mov     si, OFFSET m_title
        call    DrawString

        mov     bh, ATTR_HUD
        mov     dh, 11
        mov     dl, 28
        mov     si, OFFSET m_ctl1
        call    DrawString
        mov     dh, 12
        mov     si, OFFSET m_ctl2
        call    DrawString
        mov     dh, 13
        mov     si, OFFSET m_ctl3
        call    DrawString
        mov     dh, 14
        mov     si, OFFSET m_ctl4
        call    DrawString

        mov     bh, ATTR_PLAYER
        mov     dh, 18
        mov     dl, 30
        mov     si, OFFSET m_press
        call    DrawString

ts_wait:
        mov     ah, 00h
        int     16h
        cmp     ah, KEY_ENTER
        je      ts_done
        cmp     al, 0Dh
        je      ts_done
        cmp     ah, KEY_Q
        je      ts_quit
        cmp     al, 'q'
        je      ts_quit
        cmp     al, 'Q'
        je      ts_quit
        jmp     ts_wait
ts_quit:
        mov     byte ptr want_quit, 1
ts_done:
        pop     si
        pop     dx
        pop     bx
        pop     ax
        ret
TitleScreen ENDP

; =================================================================
;  GameOverScreen - blocks until R (restart) or Q (quit)
; =================================================================
GameOverScreen PROC
        push    ax
        push    bx
        push    dx
        push    si
        call    ClearScreen

        mov     bh, ATTR_GOVER
        mov     dh, 9
        mov     dl, 35
        mov     si, OFFSET m_gover
        call    DrawString

        mov     bh, ATTR_HUD
        mov     dh, 11
        mov     dl, 33
        mov     si, OFFSET m_final
        call    DrawString
        mov     dl, 46
        mov     al, score
        cmp     al, 0
        jge     gos_ok
        xor     al, al
gos_ok:
        mov     bh, ATTR_HUD
        call    DrawNum2

        mov     bh, ATTR_PLAYER
        mov     dh, 14
        mov     dl, 28
        mov     si, OFFSET m_opts
        call    DrawString

gos_wait:
        mov     ah, 00h
        int     16h
        cmp     ah, KEY_R
        je      gos_restart
        cmp     al, 'r'
        je      gos_restart
        cmp     al, 'R'
        je      gos_restart
        cmp     ah, KEY_Q
        je      gos_quit
        cmp     al, 'q'
        je      gos_quit
        cmp     al, 'Q'
        je      gos_quit
        jmp     gos_wait
gos_restart:
        mov     byte ptr want_restart, 1
        jmp     gos_done
gos_quit:
        mov     byte ptr want_quit, 1
gos_done:
        pop     si
        pop     dx
        pop     bx
        pop     ax
        ret
GameOverScreen ENDP

END main
