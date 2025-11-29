Simple ./ dir tracker for automated commits and pushes. Persists across boots

```
sudo nano /usr/local/bin/gitbot
sudo chmod +x /usr/local/bin/gitbot

# Start commiting and pushing changes each 300 seconds
cd your/project/path
gitbot -h start 300
```
...
```
# Stop tracking
gitbot end
```
