import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from nba_api.stats.endpoints import scoreboardv3
from nba_api.live.nba.endpoints import boxscore as live_boxscore
from datetime import datetime

# Common headers for stats.nba.com
HEADERS = {
    'Host': 'stats.nba.com',
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Origin': 'https://www.nba.com',
    'Referer': 'https://www.nba.com/',
    'Connection': 'keep-alive',
}

def get_team_leaders(players):
    if not players:
        return []
    
    def get_val(p, key):
        if 'statistics' in p:
            return p['statistics'].get(key, 0) or 0
        return 0

    sorted_players = sorted(
        players, 
        key=lambda p: (get_val(p, 'points'), get_val(p, 'reboundsTotal'), get_val(p, 'assists')), 
        reverse=True
    )
    
    leaders = []
    for p in sorted_players[:3]:
        leaders.append({
            'name': p.get('name') or 'Unknown',
            'nameI': p.get('nameI') or (p.get('name', ' ')[0] + '. ' + p.get('name', ' ').split(' ')[-1]) if p.get('name') else 'Player',
            'position': p.get('position') or '',
            'points': get_val(p, 'points'),
            'rebounds': get_val(p, 'reboundsTotal'),
            'assists': get_val(p, 'assists'),
        })
    return leaders

def fetch_game_leaders(game_id, g):
    try:
        box = live_boxscore.BoxScore(game_id)
        box_data = box.get_dict()
        game_box = box_data.get('game', {})
        if game_box:
            g['homeTeam']['leaders'] = get_team_leaders(game_box.get('homeTeam', {}).get('players', []))
            g['awayTeam']['leaders'] = get_team_leaders(game_box.get('awayTeam', {}).get('players', []))
    except Exception:
        pass

def get_primary_broadcaster(broadcasters):
    if not broadcasters:
        return "LEAGUE PASS"
    
    # Priority 1: National TV (ESPN, TNT, ABC, Amazon/Prime Video)
    # Note: nationalBroadcasters is the correct plural key for TV/Streamers in V3
    national = broadcasters.get('nationalBroadcasters', [])
    if national:
        display = national[0].get('broadcastDisplay', '')
        if display.upper() == 'AMAZON':
            return 'Prime Video'
        return display
    
    # Priority 2: National OTT (Additional streamers like Peacock)
    national_ott = broadcasters.get('nationalOttBroadcasters', [])
    if national_ott:
        return national_ott[0].get('broadcastDisplay', 'LEAGUE PASS')
    
    return "LEAGUE PASS"

def fetch_single_date(target_date):
    try:
        board = scoreboardv3.ScoreboardV3(game_date=target_date)
        data = board.get_dict()
        games_raw = data.get('scoreboard', {}).get('games', [])
        
        formatted_games = []
        leader_tasks = []
        
        with ThreadPoolExecutor(max_workers=10) as executor:
            for game in games_raw:
                game_id = game.get('gameId')
                status_id = game.get('gameStatus')
                
                home = game.get('homeTeam', {})
                away = game.get('awayTeam', {})
                broadcasters = game.get('broadcasters', {})
                
                g = {
                    'gameId': game_id,
                    'status': status_id,
                    'statusText': game.get('gameStatusText', ''),
                    'broadcaster': get_primary_broadcaster(broadcasters),
                    'homeTeam': {
                        'teamTricode': home.get('teamTricode'),
                        'score': home.get('score', 0),
                        'leaders': []
                    },
                    'awayTeam': {
                        'teamTricode': away.get('teamTricode'),
                        'score': away.get('score', 0),
                        'leaders': []
                    },
                    'period': game.get('period', 0),
                    'gameTimeUTC': game.get('gameTimeUTC', ''),
                }
                
                if status_id in [2, 3]:
                    leader_tasks.append(executor.submit(fetch_game_leaders, game_id, g))
                
                formatted_games.append(g)
            
            for task in as_completed(leader_tasks, timeout=5):
                pass
                
        return formatted_games
    except Exception as e:
        print(f"Error fetching {target_date}: {str(e)}", file=sys.stderr)
        return []

def main():
    dates = sys.argv[1:]
    if not dates:
        dates = [datetime.now().strftime('%Y-%m-%d')]
    
    results = {}
    with ThreadPoolExecutor(max_workers=max(1, len(dates))) as executor:
        future_to_date = {executor.submit(fetch_single_date, d): d for d in dates}
        for future in as_completed(future_to_date):
            date = future_to_date[future]
            try:
                results[date] = future.result()
            except Exception as e:
                results[date] = []
            
    print(json.dumps(results))

if __name__ == "__main__":
    main()
