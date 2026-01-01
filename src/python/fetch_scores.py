import json
from nba_api.live.nba.endpoints import scoreboard

def fetch_nba_scores():
    try:
        # Get today's scoreboard
        board = scoreboard.ScoreBoard()
        
        # Get the dictionary representation of the scoreboard
        data = board.get_dict()
        
        # Extract games
        games = data.get('scoreboard', {}).get('games', [])
        
        formatted_games = []
        for game in games:
            # Determine game status
            status_id = game.get('gameStatus') # 1: Upcoming, 2: In Progress, 3: Final
            status_text = game.get('gameStatusText', '')
            
            # Formatting game data for our UI
            g = {
                'gameId': game.get('gameId'),
                'status': status_id,
                'statusText': status_text,
                'homeTeam': {
                    'teamTricode': game.get('homeTeam', {}).get('teamTricode'),
                    'score': game.get('homeTeam', {}).get('score'),
                },
                'awayTeam': {
                    'teamTricode': game.get('awayTeam', {}).get('teamTricode'),
                    'score': game.get('awayTeam', {}).get('score'),
                },
                'period': game.get('period'),
                'gameTimeUTC': game.get('gameTimeUTC'),
            }
            formatted_games.append(g)
            
        print(json.dumps(formatted_games))
        
    except Exception as e:
        print(json.dumps({'error': str(e)}))

if __name__ == "__main__":
    fetch_nba_scores()
