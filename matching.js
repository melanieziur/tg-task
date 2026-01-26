function loadingBar(percent) {
  return `
    <style>
      @keyframes moveStripes {
        from { background-position: 0 0; }
        to { background-position: 40px 0; }
      }

      .progress-container {
        width: 300px;
        border: 1px solid #aaa;
        margin: 20px auto;
        background: #eee;
      }

      .progress-bar {
        height: 20px;
        width: ${percent}%;
        background-image: linear-gradient(
          45deg,
          rgba(255,255,255,0.3) 25%,
          transparent 25%,
          transparent 50%,
          rgba(255,255,255,0.3) 50%,
          rgba(255,255,255,0.3) 75%,
          transparent 75%,
          transparent
        );
        background-size: 40px 40px;
        background-color: #4CAF50;
        animation: moveStripes 1s linear infinite;
      }
    </style>

    <div class="progress-container">
      <div class="progress-bar"></div>
    </div>
  `;
}
// function getRandomInt(min, max) {
//   min = Math.ceil(min);
//   max = Math.floor(max);
//   return Math.floor(Math.random() * (max - min + 1)) + min;
// }
//
//
// var player1 = getRandomInt(1, 10);
// var player2 = getRandomInt(11, 30);
// var player3 = getRandomInt(31, 50);
// var player4 = getRandomInt(51, 70);
// var player5 = getRandomInt(71, 90);
// var player6 = getRandomInt(100);



const steps = [
  { text: "0 / 6 players joined...", pct: 100},
  { text: "1 / 6 players joined...", pct: 100},
  { text: "2 / 6 players joined...", pct: 100},
  { text: "3 / 6 players joined...", pct: 100},
  { text: "4 / 6 players joined...", pct: 100},
  { text: "5 / 6 players joined...", pct:100},
  { text: "6 / 6 players joined!", pct: 100}
];

// 🔹 Insert a fake disconnect step
const disconnectIndex = 2; // after 3 players joined
const currentCount = disconnectIndex; // 3 players

// Step showing a player left
steps.splice(disconnectIndex, 0, {
  text: `A player disconnected... <br> ${currentCount - 1} / 6 players joined... `,
  pct: 100
});

// Step showing the player rejoining (resume normal count)
steps.splice(disconnectIndex, 0, {
  text: `${currentCount} / 6 players joined...`,
  pct: 100
});

steps.forEach(step => {
  matching_timeline.push({
    type: jsPsychHtmlKeyboardResponse,
    stimulus: `
      <p>${step.text}</p>
      ${loadingBar(step.pct)}
      <p>Matching participants from other universities...</p>
    `,
    choices: "NO_KEYS",
    trial_duration: 1200 + Math.random() * 800
  });
});

/* start matching */
var partner_intro = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus:
  `<p>You have matched wth <strong>6</strong> other players! </p>
  <p> These are other participants currently completing this study as part of a collaboration with partner universities. </p>
  <p> They each provided a profile in the form of <strong> ${stim_show} </strong> for your view.</p>
  <p>Before starting the game, you will have the opportunity to view these profiles to get a sense of who you are playing with. </p>
  <p> Please press enter to start viewing! </p>
  `,
  choices: ['Enter','ENTER'],
  on_finish: function () {
   hideProgressBar(); // 🔹 ensure hidden before matching
 }
};
matching_timeline.push(partner_intro);
console.log(matching_timeline);

var profile_variables =  [
    { rank: 'T1', face: 'faces/T1.jpg', name: 'Meredith Roberts', occupation: 'therapist'},
    { rank: 'T2', face: 'faces/T2.jpg', name: 'Claire Smith', occupation: 'college professor'},
    { rank: 'T3', face: 'faces/T3.jpg', name: 'Gabriella Rodriguez', occupation: 'school teacher'},
    { rank: 'UT1', face: 'faces/UT1.jpg', name: 'Carlos Lopez', occupation: 'car salesperson'},
    { rank: 'UT2', face: 'faces/UT2.jpg', name: 'Latoya Brown', occupation: 'actor'},
    { rank: 'UT3', face: 'faces/UT3.jpg', name: 'Keisha Thomas', occupation: 'model'} ];

// Extract the stimuli for the chosen study condition
const partnerStimuli = profile_variables.map(p => p[study]);

// Display each partner
partnerStimuli.forEach(stim => {
  matching_timeline.push({
    type: jsPsychHtmlKeyboardResponse,
    stimulus: study === "face"
              ? `<img src="${stim}" style="width:200px;">`
              : `<p style="font-size:32px;">${stim}</p>`,
    choices: "NO_KEYS",
    trial_duration: 1500
  });
});
