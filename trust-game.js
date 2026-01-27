const trust_trial = {
  type: jsPsychHtmlKeyboardResponse,

  stimulus: function () {
    const p = jsPsych.timelineVariable("stim");

    let partnerDisplay;
    if (p.stm_type === "face") {
      partnerDisplay = `<img src="${p.stm}.jpg" style="width:220px;">`;
    } else {
      partnerDisplay = `<p style="font-size:36px;">${p.stm}</p>`;
    }

    return `
      <div style="text-align:center;">

        <p style="font-size:28px; margin-bottom:20px;">
          This round, you are playing with a partner.
        </p>

        ${partnerDisplay}

        <p style="font-size:24px; margin-top:30px;">
          How much would you like to send?
        </p>

        <p style="font-size:20px;">
          Press <strong>LEFT</strong> to send $${p.left}<br>
          Press <strong>RIGHT</strong> to send $${p.right}
        </p>

      </div>
    `;
  },

  choices: ["arrowleft", "arrowright"],

  data: function () {
    const p = jsPsych.timelineVariable("stim");
    return {
      trial: p.trial,
      block: p.block,
      stm_type: p.stm_type,
      stm: p.stm,
      left_amount: p.left,
      right_amount: p.right,
      profile: p.profile,
      behavior: p.behavior
    };
  },

  on_finish: function (data) {
    data.choice =
      data.response === "arrowleft" ? "left" : "right";
    data.amount_sent =
      data.response === "arrowleft"
        ? data.left_amount
        : data.right_amount;
  }
};

console.log("lol");

const trust_game = {
  timeline: [trust_trial],
  timeline_variables: test_stimuli
};
